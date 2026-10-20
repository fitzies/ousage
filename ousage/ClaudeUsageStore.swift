//
//  ClaudeUsageStore.swift
//  ousage
//

import Combine
import Foundation

nonisolated struct ClaudeUsageSnapshot: Sendable {
    let fiveHour: CodexUsageWindow?
    let weekly: CodexUsageWindow?
    /// Weekly limit scoped to the Fable model. Only the API reports it.
    var fable: CodexUsageWindow? = nil
    let fetchedAt: Date

    /// Windows whose reset time has passed have rolled over to 0%. The weekly window
    /// resets on a fixed cadence; the 5-hour one only starts again on next use.
    func rolledOver(now: Date = Date()) -> ClaudeUsageSnapshot {
        ClaudeUsageSnapshot(
            fiveHour: Self.rollOver(fiveHour, now: now, advancesReset: false),
            weekly: Self.rollOver(weekly, now: now, advancesReset: true),
            fable: Self.rollOver(fable, now: now, advancesReset: true),
            fetchedAt: fetchedAt
        )
    }

    private static func rollOver(
        _ window: CodexUsageWindow?,
        now: Date,
        advancesReset: Bool
    ) -> CodexUsageWindow? {
        guard let window, let resetsAt = window.resetsAt, resetsAt <= now else { return window }

        var nextReset: Date? = nil
        if advancesReset {
            let period = window.windowMinutes * 60
            let periodsElapsed = floor(now.timeIntervalSince(resetsAt) / period) + 1
            nextReset = resetsAt.addingTimeInterval(periodsElapsed * period)
        }

        return CodexUsageWindow(usedPercent: 0, windowMinutes: window.windowMinutes, resetsAt: nextReset)
    }
}

@MainActor
final class ClaudeUsageStore: ObservableObject {
    @Published private(set) var snapshot: ClaudeUsageSnapshot?
    @Published private(set) var isRefreshing = false
    @Published private(set) var message: String?
    @Published private(set) var plan: String?

    private let client = ClaudeUsageClient()
    private var pollingTask: Task<Void, Never>?
    private var lastAPIAttempt: Date?
    private var lastAPISuccess: Date?

    /// How long statusline data counts as current before falling back to the API.
    private static let statusLineFreshness: TimeInterval = 2 * 60
    private static let apiInterval: TimeInterval = 2 * 60
    /// The statusline doesn't include the Fable limit, so poll the API for it at this pace.
    private static let fableInterval: TimeInterval = 10 * 60

    var subtitle: String {
        guard let fetchedAt = snapshot?.fetchedAt else {
            return isRefreshing ? "Checking your limits…" : "Waiting for Claude Code"
        }
        return "Updated \(fetchedAt.formatted(.relative(presentation: .named)))"
    }

    var accessibilitySummary: String {
        let fiveHour = snapshot?.fiveHour?.formattedPercent ?? "unavailable"
        let weekly = snapshot?.weekly?.formattedPercent ?? "unavailable"
        let fable = snapshot?.fable?.formattedPercent ?? "unavailable"
        return "Claude 5-hour \(fiveHour), weekly \(weekly), Fable weekly \(fable)"
    }

    func start() {
        guard pollingTask == nil else { return }

        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh(force: false)
                try? await Task.sleep(nanoseconds: 15 * 1_000_000_000)
            }
        }
    }

    func refreshNow() {
        Task { [weak self] in
            await self?.refresh(force: true)
        }
    }

    func refreshIfStale() {
        guard let fetchedAt = snapshot?.fetchedAt,
              Date().timeIntervalSince(fetchedAt) < 30 else {
            refreshNow()
            return
        }
    }

    private func refresh(force: Bool) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        if let fromFile = ClaudeStatusLineFile.read(),
           fromFile.fetchedAt > (snapshot?.fetchedAt ?? .distantPast) {
            var merged = fromFile
            merged.fable = snapshot?.fable
            snapshot = merged
            message = nil
        }

        let now = Date()
        let isFresh = snapshot.map { now.timeIntervalSince($0.fetchedAt) < Self.statusLineFreshness } ?? false
        let apiDue = force || lastAPIAttempt.map { now.timeIntervalSince($0) >= Self.apiInterval } ?? true
        let fableStale = lastAPISuccess.map { now.timeIntervalSince($0) >= Self.fableInterval } ?? true

        if !isFresh || fableStale, apiDue {
            lastAPIAttempt = now
            do {
                let fetched = try await client.fetch()
                snapshot = fetched.snapshot
                plan = fetched.plan
                lastAPISuccess = now
                message = nil
            } catch {
                // Keep showing the last values, but say why they aren't updating once they're stale.
                if snapshot == nil || !isFresh {
                    message = error.localizedDescription
                }
            }
        }

        if let snapshot {
            self.snapshot = snapshot.rolledOver()
        }
    }
}

/// Reads the rate limits that `~/.claude/ousage-statusline.sh` saves from Claude Code's
/// statusline input. See https://code.claude.com/docs/en/statusline
private nonisolated enum ClaudeStatusLineFile {
    static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ousage/claude-rate-limits.json")
    }

    static func read() -> ClaudeUsageSnapshot? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let capturedAt = (object["captured_at"] as? NSNumber)?.doubleValue else {
            return nil
        }

        let fiveHour = parseWindow(object["five_hour"], windowMinutes: 300)
        let weekly = parseWindow(object["seven_day"], windowMinutes: 10_080)
        guard fiveHour != nil || weekly != nil else { return nil }

        return ClaudeUsageSnapshot(
            fiveHour: fiveHour,
            weekly: weekly,
            fetchedAt: Date(timeIntervalSince1970: capturedAt)
        )
    }

    private static func parseWindow(_ value: Any?, windowMinutes: Double) -> CodexUsageWindow? {
        guard let raw = value as? [String: Any],
              let usedPercent = (raw["used_percentage"] as? NSNumber)?.doubleValue else {
            return nil
        }

        return CodexUsageWindow(
            usedPercent: usedPercent,
            windowMinutes: windowMinutes,
            resetsAt: (raw["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
        )
    }
}

/// Fallback when the statusline hasn't reported recently: the undocumented endpoint
/// Claude Code's `/usage` uses, authenticated with Claude Code's own token (read-only).
private actor ClaudeUsageClient {
    /// Tries each available token, moving on when one is rejected or rate limited.
    func fetch() async throws -> (snapshot: ClaudeUsageSnapshot, plan: String?) {
        let credentials = try await ClaudeCredentials.accessTokens()

        var lastError: Error = ClaudeUsageError.notSignedIn
        for credential in credentials {
            do {
                return (try await fetch(token: credential.token), credential.plan)
            } catch let error as ClaudeUsageError where error.triesNextToken {
                lastError = error
            }
        }
        throw lastError
    }

    private func fetch(token: String) async throws -> ClaudeUsageSnapshot {
        guard let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else {
            throw ClaudeUsageError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ClaudeUsageError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200..<300:
            break
        case 401, 403:
            throw ClaudeUsageError.unauthorized
        case 429:
            throw ClaudeUsageError.rateLimited
        default:
            throw ClaudeUsageError.serverError(httpResponse.statusCode)
        }

        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeUsageError.invalidResponse
        }

        let fiveHour = Self.parseWindow(object["five_hour"], windowMinutes: 300)
        let weekly = Self.parseWindow(object["seven_day"], windowMinutes: 10_080)

        guard fiveHour != nil || weekly != nil else {
            throw ClaudeUsageError.noLimits
        }

        return ClaudeUsageSnapshot(
            fiveHour: fiveHour,
            weekly: weekly,
            fable: Self.parseFableWindow(object["limits"]),
            fetchedAt: Date()
        )
    }

    /// Model-scoped weekly limits appear in `limits` as `weekly_scoped` entries.
    private static func parseFableWindow(_ value: Any?) -> CodexUsageWindow? {
        guard let limits = value as? [[String: Any]] else { return nil }

        let fable = limits.first { limit in
            guard limit["kind"] as? String == "weekly_scoped",
                  let scope = limit["scope"] as? [String: Any],
                  let model = scope["model"] as? [String: Any],
                  let name = model["display_name"] as? String else {
                return false
            }
            return name.localizedCaseInsensitiveContains("fable")
        }

        guard let fable, let percent = (fable["percent"] as? NSNumber)?.doubleValue else { return nil }

        return CodexUsageWindow(
            usedPercent: percent,
            windowMinutes: 10_080,
            resetsAt: (fable["resets_at"] as? String).flatMap(parseISODate)
        )
    }

    private static func parseWindow(_ value: Any?, windowMinutes: Double) -> CodexUsageWindow? {
        guard let raw = value as? [String: Any],
              let utilization = (raw["utilization"] as? NSNumber)?.doubleValue else {
            return nil
        }

        return CodexUsageWindow(
            usedPercent: utilization,
            windowMinutes: windowMinutes,
            resetsAt: (raw["resets_at"] as? String).flatMap(parseISODate)
        )
    }

    private static func parseISODate(_ raw: String) -> Date? {
        // The API returns microsecond precision, which ISO8601DateFormatter can't parse.
        let trimmed = raw.replacingOccurrences(
            of: #"\.\d+"#,
            with: "",
            options: .regularExpression
        )
        return ISO8601DateFormatter().date(from: trimmed)
    }
}

/// Reads Claude Code's OAuth token (read-only; never refreshed here, so Claude Code stays signed in).
/// Claude Code mostly runs on `forge`, whose token stays fresh while it's in use, so try that first
/// and fall back to the local keychain when the server is unreachable or its token is rejected.
private nonisolated enum ClaudeCredentials {
    private static let remoteHost = "forge"

    static func accessTokens() async throws -> [(token: String, plan: String?)] {
        var tokens: [(token: String, plan: String?)] = []

        if let data = try? await run("/usr/bin/ssh", [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=5",
            remoteHost,
            "cat ~/.claude/.credentials.json",
        ]), let token = try? parseToken(data) {
            tokens.append(token)
        }

        // Going through `/usr/bin/security` matches how Claude Code writes the item, so no keychain prompt appears.
        var keychainError: Error?
        do {
            let data = try await run("/usr/bin/security", ["find-generic-password", "-s", "Claude Code-credentials", "-w"])
            let token = try parseToken(data)
            if !tokens.contains(where: { $0.token == token.token }) {
                tokens.append(token)
            }
        } catch {
            keychainError = error
        }

        // Claude Code's plain-file login (used on Linux, and on macOS when the Keychain is unavailable).
        let configDir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        if let data = try? Data(contentsOf: configDir.appendingPathComponent(".credentials.json")),
           let token = try? parseToken(data),
           !tokens.contains(where: { $0.token == token.token }) {
            tokens.append(token)
        }

        if tokens.isEmpty {
            // Say why the Keychain login couldn't be used (e.g. expired) rather than a generic error.
            throw keychainError ?? ClaudeUsageError.notSignedIn
        }
        return tokens
    }

    private static func parseToken(_ data: Data) throws -> (token: String, plan: String?) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = object["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String,
              !token.isEmpty else {
            throw ClaudeUsageError.notSignedIn
        }

        if let expiresAt = (oauth["expiresAt"] as? NSNumber)?.doubleValue,
           Date(timeIntervalSince1970: expiresAt / 1000) < Date() {
            throw ClaudeUsageError.tokenExpired
        }

        return (token, planName(
            subscriptionType: oauth["subscriptionType"] as? String,
            rateLimitTier: oauth["rateLimitTier"] as? String
        ))
    }

    private static func planName(subscriptionType: String?, rateLimitTier: String?) -> String? {
        guard let type = subscriptionType?.lowercased(), !type.isEmpty else { return nil }

        if type == "max", let tier = rateLimitTier?.lowercased() {
            if tier.contains("20x") { return "Max 20x" }
            if tier.contains("5x") { return "Max 5x" }
        }
        return type.capitalized
    }

    private static func run(_ executable: String, _ arguments: [String]) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice

            process.terminationHandler = { process in
                let data = output.fileHandleForReading.readDataToEndOfFile()
                if process.terminationStatus == 0, !data.isEmpty {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: ClaudeUsageError.notSignedIn)
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: ClaudeUsageError.notSignedIn)
            }
        }
    }
}

private enum ClaudeUsageError: LocalizedError {
    case notSignedIn
    case tokenExpired
    case unauthorized
    case rateLimited
    case serverError(Int)
    case invalidResponse
    case noLimits

    /// Errors specific to one token, where another token may still work.
    var triesNextToken: Bool {
        switch self {
        case .unauthorized, .rateLimited:
            return true
        default:
            return false
        }
    }

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "Claude Code credentials weren’t found. Sign in with `claude` first."
        case .tokenExpired:
            return "Claude Code’s token has expired. Run `claude` to refresh it."
        case .unauthorized:
            return "Claude rejected the stored token. Run `claude` to sign in again."
        case .rateLimited:
            return "Claude is rate limiting usage checks. Trying again shortly."
        case .serverError(let status):
            return "Claude usage request failed (HTTP \(status))."
        case .invalidResponse:
            return "Claude returned usage in an unexpected format."
        case .noLimits:
            return "Claude did not report a 5-hour or weekly usage window."
        }
    }
}
