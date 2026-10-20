//
//  CodexUsageStore.swift
//  ousage
//

import Combine
import Foundation

nonisolated enum UsagePace: Sendable {
    case onPace
    case nearPace
    case aheadOfPace
    case neutral
}

nonisolated struct CodexUsageWindow: Sendable {
    let usedPercent: Double
    let windowMinutes: Double
    let resetsAt: Date?

    var clampedPercent: Double {
        min(100, max(0, usedPercent))
    }

    var formattedPercent: String {
        "\(Int(clampedPercent.rounded()))%"
    }

    var paceAllowancePercent: Double? {
        guard let resetsAt, windowMinutes > 0 else { return nil }

        let windowSeconds = windowMinutes * 60
        let remainingSeconds = max(0, resetsAt.timeIntervalSinceNow)
        let elapsedSeconds = max(0, min(windowSeconds, windowSeconds - remainingSeconds))
        return elapsedSeconds / windowSeconds * 100
    }

    var formattedPaceAllowance: String? {
        paceAllowancePercent.map { "\(Int($0.rounded()))%" }
    }

    var pace: UsagePace {
        guard let expectedPercent = paceAllowancePercent else {
            if clampedPercent >= 90 { return .aheadOfPace }
            if clampedPercent >= 80 { return .nearPace }
            return .neutral
        }

        let grace = windowMinutes <= 302 ? 5.0 : 3.0
        let allowedPercent = expectedPercent + grace

        if clampedPercent <= allowedPercent { return .onPace }
        if clampedPercent <= allowedPercent + 10 { return .nearPace }
        return .aheadOfPace
    }

    var resetDescription: String? {
        guard let resetsAt else { return nil }

        let remainingMinutes = max(0, Int(ceil(resetsAt.timeIntervalSinceNow / 60)))
        let days = remainingMinutes / (24 * 60)
        let hours = (remainingMinutes % (24 * 60)) / 60
        let minutes = remainingMinutes % 60
        let relative: String

        if days > 0 {
            relative = "\(days)d \(hours)h"
        } else if hours > 0 {
            relative = "\(hours)h \(minutes)m"
        } else {
            relative = "\(minutes)m"
        }

        return "resets \(resetsAt.formatted(.dateTime.weekday(.abbreviated).hour().minute())) · \(relative)"
    }
}

nonisolated struct CodexUsageSnapshot: Sendable {
    let fiveHour: CodexUsageWindow?
    let weekly: CodexUsageWindow?
    /// The free plan only has a 30-day window.
    let monthly: CodexUsageWindow?
    let fetchedAt: Date
}

@MainActor
final class CodexUsageStore: ObservableObject {
    @Published private(set) var snapshot: CodexUsageSnapshot?
    @Published private(set) var isRefreshing = false
    @Published private(set) var message: String?
    @Published private(set) var plan: String?

    private let client = CodexUsageClient()
    private var pollingTask: Task<Void, Never>?

    var subtitle: String {
        guard let fetchedAt = snapshot?.fetchedAt else {
            return isRefreshing ? "Checking your limits…" : "Waiting for Codex"
        }
        return "Updated \(fetchedAt.formatted(.relative(presentation: .named)))"
    }

    var accessibilitySummary: String {
        let fiveHour = snapshot?.fiveHour?.formattedPercent ?? "unavailable"
        let weekly = snapshot?.weekly?.formattedPercent ?? "unavailable"
        return "5-hour \(fiveHour), weekly \(weekly)"
    }

    func start() {
        guard pollingTask == nil else { return }

        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                try? await Task.sleep(nanoseconds: 2 * 60 * 1_000_000_000)
            }
        }
    }

    func refreshNow() {
        Task { [weak self] in
            await self?.refresh()
        }
    }

    func refreshIfStale() {
        guard let fetchedAt = snapshot?.fetchedAt,
              Date().timeIntervalSince(fetchedAt) < 30 else {
            refreshNow()
            return
        }
    }

    private func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            let fetched = try await client.fetch()
            snapshot = fetched.snapshot
            plan = fetched.plan
            message = nil
        } catch {
            message = error.localizedDescription
        }
    }
}

private actor CodexUsageClient {
    func fetch() async throws -> AppServerRequest.Response {
        do {
            let executable = try codexExecutableURL()
            return try await AppServerRequest(executableURL: executable).run()
        } catch {
            // Without a working CLI, ask the same usage endpoint directly with Codex's saved login.
            if let fallback = try? await CodexAuthFileUsage.fetch() { return fallback }
            throw error
        }
    }

    private func codexExecutableURL() throws -> URL {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        var candidates = [
            home.appendingPathComponent(".local/bin/codex"),
            URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
            URL(fileURLWithPath: "/usr/local/bin/codex"),
        ]

        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map {
                URL(fileURLWithPath: String($0)).appendingPathComponent("codex")
            })
        }

        guard let executable = candidates.first(where: {
            fileManager.isExecutableFile(atPath: $0.path)
        }) else {
            throw CodexUsageError.cliNotFound
        }

        return executable
    }
}

private nonisolated final class AppServerRequest: @unchecked Sendable {
    typealias Response = (snapshot: CodexUsageSnapshot, plan: String?)

    private let executableURL: URL
    private let process = Process()
    private let inputPipe = Pipe()
    private let outputPipe = Pipe()
    private let lock = NSLock()
    private var buffer = Data()
    private var isFinished = false
    private var snapshot: CodexUsageSnapshot?
    private var accountPlan: String?
    private var rateLimitPlan: String?
    private var accountAnswered = false
    private var continuation: CheckedContinuation<Response, Error>?

    init(executableURL: URL) {
        self.executableURL = executableURL
    }

    func run() async throws -> Response {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()

            process.executableURL = executableURL
            process.arguments = ["app-server", "--stdio"]
            process.standardInput = inputPipe
            process.standardOutput = outputPipe
            process.standardError = FileHandle.nullDevice

            outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                self?.receive(data)
            }

            process.terminationHandler = { [weak self] process in
                self?.finish(orFailWith: CodexUsageError.serverStopped)
            }

            do {
                try process.run()
                try inputPipe.fileHandleForWriting.write(contentsOf: Self.initializeRequestData)
            } catch {
                finish(.failure(CodexUsageError.couldNotStart(error.localizedDescription)))
                return
            }

            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 15) { [weak self] in
                self?.finish(orFailWith: CodexUsageError.timedOut)
            }
        }
    }

    private func receive(_ data: Data) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        buffer.append(data)

        var completeLines = [Data]()
        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
            completeLines.append(buffer[..<newlineIndex])
            buffer.removeSubrange(...newlineIndex)
        }
        lock.unlock()

        for line in completeLines where !line.isEmpty {
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let responseID = (object["id"] as? NSNumber)?.intValue else {
                continue
            }

            // The plan is a nice-to-have, so a failed `account/read` still returns the rate limits.
            if responseID == 3 {
                let accountPlan = Self.parsePlan(from: object)
                lock.lock()
                accountAnswered = true
                self.accountPlan = accountPlan
                lock.unlock()
                finishIfComplete()
                continue
            }

            if let error = object["error"] as? [String: Any] {
                let detail = error["message"] as? String ?? "Codex returned an error."
                finish(.failure(CodexUsageError.serverError(detail)))
                return
            }

            if responseID == 1 {
                do {
                    try inputPipe.fileHandleForWriting.write(contentsOf: Self.usageRequestData)
                } catch {
                    finish(.failure(CodexUsageError.couldNotStart(error.localizedDescription)))
                }
                continue
            }

            guard responseID == 2 else { continue }

            do {
                let newSnapshot = try Self.parseSnapshot(from: object)
                let rateLimitPlan = Self.parsePlan(from: object)
                lock.lock()
                snapshot = newSnapshot
                self.rateLimitPlan = rateLimitPlan
                lock.unlock()
                finishIfComplete()
            } catch {
                finish(.failure(error))
                return
            }
        }
    }

    private func finishIfComplete() {
        lock.lock()
        let isComplete = snapshot != nil && accountAnswered
        lock.unlock()

        if isComplete {
            finish(orFailWith: CodexUsageError.invalidResponse)
        }
    }

    /// Returns the rate limits if they arrived, even when the plan didn't.
    private func finish(orFailWith error: Error) {
        lock.lock()
        let response = snapshot.map { (snapshot: $0, plan: accountPlan ?? rateLimitPlan) }
        lock.unlock()

        finish(response.map { .success($0) } ?? .failure(error))
    }

    private func finish(_ result: Result<Response, Error>) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        let continuation = continuation
        self.continuation = nil
        lock.unlock()

        outputPipe.fileHandleForReading.readabilityHandler = nil
        try? inputPipe.fileHandleForWriting.close()
        if process.isRunning {
            process.terminate()
        }
        continuation?.resume(with: result)
    }

    private static let initializeRequestData = Data(
        """
        {"id":1,"method":"initialize","params":{"clientInfo":{"name":"ousage","title":"ousage","version":"1.0"},"capabilities":{"experimentalApi":true}}}

        """.utf8
    )

    private static let usageRequestData = Data(
        """
        {"method":"initialized"}
        {"id":2,"method":"account/rateLimits/read","params":null}
        {"id":3,"method":"account/read","params":{}}

        """.utf8
    )

    private static func parseSnapshot(from response: [String: Any]) throws -> CodexUsageSnapshot {
        guard let result = response["result"] as? [String: Any] else {
            throw CodexUsageError.invalidResponse
        }

        guard let base = result["rateLimits"] as? [String: Any] else {
            throw CodexUsageError.invalidResponse
        }

        let baseWindows = [base["primary"], base["secondary"]]
            .compactMap(parseWindow)
        let fiveHour = matchingWindow(minutes: 300, in: baseWindows)
        let weekly = matchingWindow(minutes: 10_080, in: baseWindows)
        let monthly = baseWindows.first { (40_000...45_000).contains($0.windowMinutes) }

        guard fiveHour != nil || weekly != nil || monthly != nil else {
            throw CodexUsageError.noLimits
        }

        return CodexUsageSnapshot(fiveHour: fiveHour, weekly: weekly, monthly: monthly, fetchedAt: Date())
    }

    /// `account/read` reports `result.account.planType`; `account/rateLimits/read` reports `result.rateLimits.planType`.
    private static func parsePlan(from response: [String: Any]) -> String? {
        guard let result = response["result"] as? [String: Any],
              let container = (result["account"] ?? result["rateLimits"]) as? [String: Any],
              let planType = (container["planType"] as? String)?.lowercased(),
              !planType.isEmpty, planType != "unknown" else {
            return nil
        }

        if planType.contains("enterprise") { return "Enterprise" }
        if planType.contains("business") { return "Business" }
        return planType.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private static func parseWindow(_ value: Any?) -> CodexUsageWindow? {
        guard let raw = value as? [String: Any],
              let usedPercent = (raw["usedPercent"] as? NSNumber)?.doubleValue,
              let windowMinutes = (raw["windowDurationMins"] as? NSNumber)?.doubleValue else {
            return nil
        }

        let resetSeconds = (raw["resetsAt"] as? NSNumber)?.doubleValue
        return CodexUsageWindow(
            usedPercent: usedPercent,
            windowMinutes: windowMinutes,
            resetsAt: resetSeconds.map { Date(timeIntervalSince1970: $0) }
        )
    }

    private static func matchingWindow(
        minutes: Double,
        in windows: [CodexUsageWindow]
    ) -> CodexUsageWindow? {
        windows.first { abs($0.windowMinutes - minutes) <= 2 }
    }

}

/// `chatgpt.com/backend-api/wham/usage` with the ChatGPT login Codex saved in `~/.codex/auth.json`
/// (or `$CODEX_HOME`). Read-only: tokens are never refreshed here, so Codex's own login isn't rotated.
private nonisolated enum CodexAuthFileUsage {
    static func fetch() async throws -> AppServerRequest.Response {
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        guard let data = try? Data(contentsOf: home.appendingPathComponent("auth.json")),
              let auth = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = auth["tokens"] as? [String: Any],
              let token = tokens["access_token"] as? String, !token.isEmpty,
              let url = URL(string: "https://chatgpt.com/backend-api/wham/usage") else {
            throw CodexUsageError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("ousage", forHTTPHeaderField: "User-Agent")
        if let account = tokens["account_id"] as? String, !account.isEmpty {
            request.setValue(account, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        let (body, response) = try await URLSession.shared.data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode else { throw CodexUsageError.invalidResponse }
        guard (200..<300).contains(status) else {
            throw CodexUsageError.serverError(status == 401 || status == 403
                ? "Codex’s saved sign-in was rejected. Run `codex` to sign in again."
                : "Codex usage request failed (HTTP \(status)).")
        }
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let limits = object["rate_limit"] as? [String: Any] else {
            throw CodexUsageError.invalidResponse
        }

        let windows = [limits["primary_window"], limits["secondary_window"]].compactMap { value -> CodexUsageWindow? in
            guard let raw = value as? [String: Any],
                  let used = (raw["used_percent"] as? NSNumber)?.doubleValue,
                  let seconds = (raw["limit_window_seconds"] as? NSNumber)?.doubleValue else { return nil }
            let reset = (raw["reset_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            return CodexUsageWindow(usedPercent: used, windowMinutes: seconds / 60, resetsAt: reset)
        }
        let fiveHour = windows.first { abs($0.windowMinutes - 300) <= 2 }
        let weekly = windows.first { abs($0.windowMinutes - 10_080) <= 2 }
        let monthly = windows.first { (40_000...45_000).contains($0.windowMinutes) }
        guard fiveHour != nil || weekly != nil || monthly != nil else { throw CodexUsageError.noLimits }

        let planType = (object["plan_type"] as? String)?.lowercased()
        let plan: String? = switch planType {
        case nil, "", "unknown": nil
        case let type? where type.contains("enterprise"): "Enterprise"
        case let type? where type.contains("business"): "Business"
        case let type?: type.replacingOccurrences(of: "_", with: " ").capitalized
        }

        return (CodexUsageSnapshot(fiveHour: fiveHour, weekly: weekly, monthly: monthly, fetchedAt: Date()), plan)
    }
}

private enum CodexUsageError: LocalizedError {
    case cliNotFound
    case couldNotStart(String)
    case serverStopped
    case serverError(String)
    case invalidResponse
    case noLimits
    case timedOut

    var errorDescription: String? {
        switch self {
        case .cliNotFound:
            return "Codex CLI was not found. Install Codex or add it to ~/.local/bin."
        case .couldNotStart(let detail):
            return "Couldn’t start Codex: \(detail)"
        case .serverStopped:
            return "Codex stopped before returning usage."
        case .serverError(let detail):
            return detail
        case .invalidResponse:
            return "Codex returned usage in an unexpected format."
        case .noLimits:
            return "Codex did not report a usage window."
        case .timedOut:
            return "Codex took too long to return usage."
        }
    }
}
