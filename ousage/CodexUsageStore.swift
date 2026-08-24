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
    let fetchedAt: Date
}

@MainActor
final class CodexUsageStore: ObservableObject {
    @Published private(set) var snapshot: CodexUsageSnapshot?
    @Published private(set) var isRefreshing = false
    @Published private(set) var message: String?

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
            let newSnapshot = try await client.fetch()
            snapshot = newSnapshot
            message = nil
        } catch {
            message = error.localizedDescription
        }
    }
}

private actor CodexUsageClient {
    func fetch() async throws -> CodexUsageSnapshot {
        let executable = try codexExecutableURL()
        return try await AppServerRequest(executableURL: executable).run()
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
    private let executableURL: URL
    private let process = Process()
    private let inputPipe = Pipe()
    private let outputPipe = Pipe()
    private let lock = NSLock()
    private var buffer = Data()
    private var isFinished = false
    private var continuation: CheckedContinuation<CodexUsageSnapshot, Error>?

    init(executableURL: URL) {
        self.executableURL = executableURL
    }

    func run() async throws -> CodexUsageSnapshot {
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
                self?.finish(.failure(CodexUsageError.serverStopped))
            }

            do {
                try process.run()
                try inputPipe.fileHandleForWriting.write(contentsOf: Self.initializeRequestData)
            } catch {
                finish(.failure(CodexUsageError.couldNotStart(error.localizedDescription)))
                return
            }

            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 15) { [weak self] in
                self?.finish(.failure(CodexUsageError.timedOut))
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
                finish(.success(try Self.parseSnapshot(from: object)))
            } catch {
                finish(.failure(error))
            }
            return
        }
    }

    private func finish(_ result: Result<CodexUsageSnapshot, Error>) {
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

        guard fiveHour != nil || weekly != nil else {
            throw CodexUsageError.noLimits
        }

        return CodexUsageSnapshot(fiveHour: fiveHour, weekly: weekly, fetchedAt: Date())
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
            return "Codex did not report a 5-hour or weekly usage window."
        case .timedOut:
            return "Codex took too long to return usage."
        }
    }
}
