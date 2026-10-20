//
//  GrokUsageStore.swift
//  ousage
//

import CommonCrypto
import Combine
import Foundation

nonisolated struct GrokUsageSnapshot: Sendable {
    /// SuperGrok's weekly usage pool, as grok.com shows it.
    var superGrok: CodexUsageWindow?
    /// Grok Bot's weekly allowance from the SuperGrok plan.
    var grokBot: CodexUsageWindow?
    var fetchedAt: Date

    var isEmpty: Bool { superGrok == nil && grokBot == nil }

    /// Once a weekly reset passes the week starts again at 0%, until the next fetch says otherwise.
    func rolledOver(now: Date = Date()) -> GrokUsageSnapshot {
        var snapshot = self
        snapshot.superGrok = Self.rollOver(superGrok, now: now)
        snapshot.grokBot = Self.rollOver(grokBot, now: now)
        return snapshot
    }

    private static func rollOver(_ window: CodexUsageWindow?, now: Date) -> CodexUsageWindow? {
        guard let window, let resetsAt = window.resetsAt, resetsAt <= now else { return window }

        let period = window.windowMinutes * 60
        let periodsElapsed = floor(now.timeIntervalSince(resetsAt) / period) + 1
        return CodexUsageWindow(
            usedPercent: 0,
            windowMinutes: window.windowMinutes,
            resetsAt: resetsAt.addingTimeInterval(periodsElapsed * period)
        )
    }
}

@MainActor
final class GrokUsageStore: ObservableObject {
    @Published private(set) var snapshot: GrokUsageSnapshot?
    @Published private(set) var isRefreshing = false
    /// Why Grok Bot's allowance isn't updating.
    @Published private(set) var message: String?
    /// Why grok.com's SuperGrok limits aren't updating.
    @Published private(set) var webMessage: String?
    @Published private(set) var needsWebConnection = false
    @Published private(set) var plan: String?

    private let client = GrokUsageClient()
    private let web = GrokWebSession()
    private var pollingTask: Task<Void, Never>?

    func start() {
        guard pollingTask == nil else { return }

        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                try? await Task.sleep(nanoseconds: 5 * 60 * 1_000_000_000)
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

    /// Opens grok.com once so Cloudflare and sign-in can complete; later checks run hidden.
    func connectGrokCom() {
        web.verify { [weak self] in
            self?.refreshNow()
        }
    }

    /// Where the SuperGrok weekly limit last came from.
    @Published private(set) var usesGrokCLI = false

    private let cli = GrokCLIClient()

    private func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        var updated = snapshot ?? GrokUsageSnapshot(fetchedAt: Date())
        var didUpdate = false

        // The Grok CLI's own login reports both the weekly pool and Grok Bot's share of it,
        // so grok.com and Grok Bot's Keychain item are only needed when it isn't signed in.
        var cliError: Error?
        if GrokCLIAuth.exists {
            switch await Self.capture({ try await self.cli.fetch() }) {
            case .success(let usage):
                updated.superGrok = usage.weekly
                if let grokBot = usage.grokBot { updated.grokBot = grokBot }
                plan = usage.plan ?? plan
                usesGrokCLI = true
                webMessage = nil
                needsWebConnection = false
                didUpdate = true
                if usage.grokBot != nil {
                    message = nil
                    updated.fetchedAt = Date()
                    snapshot = updated.rolledOver()
                    return
                }
            case .failure(let error):
                cliError = error
                usesGrokCLI = false
            }
        }

        let cliSucceeded = didUpdate
        async let botResult = Self.capture { try await self.client.fetch() }
        var webResult: Result<GrokWebUsage, Error>?
        if !cliSucceeded {
            webResult = await Self.capture { try await self.web.fetch() }
        }

        switch await botResult {
        case .success(let fetched):
            updated.grokBot = fetched.weekly
            if !cliSucceeded { plan = fetched.plan ?? plan }
            message = nil
            didUpdate = true
        case .failure(let error):
            message = error.localizedDescription
        }

        switch webResult {
        case .success(let usage):
            updated.superGrok = usage.pool
            webMessage = nil
            needsWebConnection = false
            didUpdate = true
        case .failure(let error):
            // The CLI's error is the more useful one when it's signed in but failing.
            webMessage = cliError?.localizedDescription ?? error.localizedDescription
            needsWebConnection = (error as? GrokWebError)?.needsConnection ?? false
        case nil:
            break
        }

        if didUpdate { updated.fetchedAt = Date() }
        snapshot = updated.isEmpty ? nil : updated.rolledOver()
    }

    private static func capture<T>(_ work: () async throws -> T) async -> Result<T, Error> {
        do { return .success(try await work()) } catch { return .failure(error) }
    }
}

/// The endpoint Grok Bot's own usage meter calls, authenticated with Grok Bot's token (read-only;
/// never refreshed here, so Grok Bot stays signed in). The SuperGrok allowance is a weekly percentage.
private actor GrokUsageClient {
    private var storageKey: Data?

    func fetch() async throws -> (weekly: CodexUsageWindow, plan: String?) {
        let token = try await accessToken()

        guard let url = URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetSandUsageStatus") else {
            throw GrokUsageError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.httpBody = Data("{}".utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GrokUsageError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200..<300:
            break
        case 401, 403:
            throw GrokUsageError.unauthorized
        case 429:
            throw GrokUsageError.rateLimited
        default:
            throw GrokUsageError.serverError(httpResponse.statusCode)
        }

        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GrokUsageError.invalidResponse
        }

        // Pooled team allowances don't report a personal percentage, matching Grok Bot.
        guard object["usesPooledEnterpriseAllowance"] as? Bool != true,
              let usedPercent = (object["usagePercent"] as? NSNumber)?.doubleValue else {
            throw GrokUsageError.noLimits
        }

        let periodStart = (object["currentPeriodStart"] as? String).flatMap(Self.parseISODate)
        let resetsAt = (object["nextResetTimestampUtc"] as? String).flatMap(Self.parseISODate)
        let windowMinutes: Double = if let periodStart, let resetsAt, resetsAt > periodStart {
            resetsAt.timeIntervalSince(periodStart) / 60
        } else {
            10_080
        }

        let plan = (object["grokPlanLabel"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let weekly = CodexUsageWindow(usedPercent: max(0, usedPercent), windowMinutes: windowMinutes, resetsAt: resetsAt)
        return (weekly, plan)
    }

    /// Grok Bot keeps its Cursor account tokens in `sand-secrets.json`, sealed with Electron's
    /// safeStorage: "v10" + AES-128-CBC under a key derived from its Keychain password.
    private func accessToken() async throws -> String {
        guard let data = try? Data(contentsOf: GrokBotFiles.secrets),
              let secrets = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accountsJSON = (secrets["cursor-accounts"] as? String)?.data(using: .utf8),
              let accounts = try? JSONSerialization.jsonObject(with: accountsJSON) as? [String: Any],
              let active = accounts["active"] as? String,
              let account = (accounts["accounts"] as? [String: Any])?[active] as? [String: Any],
              let sealed = account["cursor-access-token"] as? String else {
            throw GrokUsageError.notSignedIn
        }

        let key = try await safeStorageKey()
        guard let token = Self.decrypt(sealed, key: key), !token.isEmpty else {
            // The Keychain password may have changed since it was cached; read it again next time.
            storageKey = nil
            throw GrokUsageError.unreadableToken
        }

        if let expiresAt = Self.expiry(ofJWT: token), expiresAt < Date() {
            throw GrokUsageError.tokenExpired
        }
        return token
    }

    private func safeStorageKey() async throws -> Data {
        if let storageKey { return storageKey }

        // Through `/usr/bin/security`, so "Always Allow" on its Keychain prompt sticks across rebuilds.
        let password = try await Self.run("/usr/bin/security", ["find-generic-password", "-s", "Grok Bot Safe Storage", "-w"])
        let trimmed = password.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw GrokUsageError.keychainDenied }

        var key = Data(count: kCCKeySizeAES128)
        let salt = Data("saltysalt".utf8)
        let status = key.withUnsafeMutableBytes { keyBytes in
            salt.withUnsafeBytes { saltBytes in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    trimmed, trimmed.utf8.count,
                    saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                    1003,
                    keyBytes.bindMemory(to: UInt8.self).baseAddress, kCCKeySizeAES128
                )
            }
        }
        guard status == kCCSuccess else { throw GrokUsageError.unreadableToken }

        storageKey = key
        return key
    }

    private static func decrypt(_ sealed: String, key: Data) -> String? {
        guard let raw = Data(base64Encoded: sealed), raw.starts(with: Data("v10".utf8)) else { return nil }

        let ciphertext = raw.dropFirst(3)
        let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)
        var output = Data(count: ciphertext.count + kCCBlockSizeAES128)
        var outputLength = 0

        let status = output.withUnsafeMutableBytes { outputBytes in
            ciphertext.withUnsafeBytes { inputBytes in
                iv.withUnsafeBytes { ivBytes in
                    key.withUnsafeBytes { keyBytes in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress, key.count,
                            ivBytes.baseAddress,
                            inputBytes.baseAddress, ciphertext.count,
                            outputBytes.baseAddress, outputBytes.count,
                            &outputLength
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        return String(data: output.prefix(outputLength), encoding: .utf8)
    }

    private static func expiry(ofJWT token: String) -> Date? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }

        var payload = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = (claims["exp"] as? NSNumber)?.doubleValue else {
            return nil
        }
        return Date(timeIntervalSince1970: exp)
    }

    private static func parseISODate(_ raw: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
    }

    private static func run(_ executable: String, _ arguments: [String]) async throws -> String {
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
                if process.terminationStatus == 0, let text = String(data: data, encoding: .utf8) {
                    continuation.resume(returning: text)
                } else {
                    continuation.resume(throwing: GrokUsageError.keychainDenied)
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: GrokUsageError.keychainDenied)
            }
        }
    }
}

/// The billing endpoint the Grok CLI itself calls, authenticated with its own `~/.grok/auth.json` login.
/// Tokens are refreshed like the CLI does and written back, so both stay signed in.
private actor GrokCLIClient {
    private static let proxy = "https://cli-chat-proxy.grok.com/v1"

    func fetch() async throws -> (weekly: CodexUsageWindow?, grokBot: CodexUsageWindow?, plan: String?) {
        var auth = try GrokCLIAuth.load()
        if auth.isExpiring, let refreshed = try? await refresh(auth) {
            auth = refreshed
        }

        var (data, status) = try await get("billing?format=credits", token: auth.token)
        if status == 401 || status == 403 {
            guard let refreshed = try await refresh(auth) else { throw GrokCLIError.expired }
            auth = refreshed
            (data, status) = try await get("billing?format=credits", token: auth.token)
        }

        switch status {
        case 200..<300: break
        case 401, 403: throw GrokCLIError.expired
        case 412: throw GrokCLIError.teamAccount
        default: throw GrokCLIError.serverError(status)
        }

        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let config = object["config"] as? [String: Any],
              let period = config["currentPeriod"] as? [String: Any],
              let start = (period["start"] as? String).flatMap(Self.parseISODate),
              let end = (period["end"] as? String).flatMap(Self.parseISODate),
              end > start else {
            throw GrokCLIError.invalidResponse
        }

        // Accounts not yet on unified weekly billing have no weekly pool to show.
        guard period["type"] as? String == "USAGE_PERIOD_TYPE_WEEKLY" else { throw GrokCLIError.noWeeklyPool }

        let minutes = end.timeIntervalSince(start) / 60
        // Proto-JSON drops zero values, so a missing percent is 0%.
        let percent = (config["creditUsagePercent"] as? NSNumber)?.doubleValue ?? 0
        let weekly = CodexUsageWindow(usedPercent: max(0, percent), windowMinutes: minutes, resetsAt: end)

        let products = config["productUsage"] as? [[String: Any]] ?? []
        let grokBot = products.first { ($0["product"] as? String)?.lowercased() == "grokbot" }.map {
            CodexUsageWindow(
                usedPercent: max(0, ($0["usagePercent"] as? NSNumber)?.doubleValue ?? 0),
                windowMinutes: minutes,
                resetsAt: end
            )
        }

        return (weekly, grokBot, await plan(token: auth.token))
    }

    private func plan(token: String) async -> String? {
        guard let (data, status) = try? await get("settings", token: token),
              (200..<300).contains(status),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tier = (object["subscription_tier_display"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !tier.isEmpty else {
            return nil
        }
        return tier
    }

    private func get(_ path: String, token: String) async throws -> (Data, Int) {
        guard let url = URL(string: "\(Self.proxy)/\(path)") else { throw GrokCLIError.invalidResponse }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("xai-grok-cli", forHTTPHeaderField: "X-XAI-Token-Auth")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("ousage", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    private func refresh(_ auth: GrokCLIAuth) async throws -> GrokCLIAuth? {
        guard let refreshToken = auth.refreshToken,
              let url = URL(string: "https://auth.x.ai/oauth2/token") else { return nil }

        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        func encode(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("grant_type=refresh_token&client_id=\(encode(auth.clientID))&refresh_token=\(encode(refreshToken))".utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = (object["access_token"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else {
            return nil
        }

        let expiresIn = (object["expires_in"] as? NSNumber)?.doubleValue
        let expiresAt = expiresIn.map { Date().addingTimeInterval($0) } ?? GrokCLIAuth.jwtExpiry(token) ?? Date().addingTimeInterval(3600)
        let updated = GrokCLIAuth(
            entryKey: auth.entryKey,
            token: token,
            refreshToken: (object["refresh_token"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? auth.refreshToken,
            idToken: (object["id_token"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            expiresAt: expiresAt,
            clientID: auth.clientID
        )
        // Rotated tokens must reach the CLI too, or its next refresh would fail.
        try? updated.save()
        return updated
    }

    private static func parseISODate(_ raw: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) { return date }
        // Python-style microseconds and offsets, e.g. 2026-07-03T04:01:09.238389+00:00.
        let trimmed = raw.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        return ISO8601DateFormatter().date(from: trimmed)
    }
}

/// The Grok CLI's login in `~/.grok/auth.json`, keyed by `<issuer>::<client id>`.
nonisolated struct GrokCLIAuth: Sendable {
    let entryKey: String
    let token: String
    let refreshToken: String?
    var idToken: String? = nil
    let expiresAt: Date?
    let clientID: String

    static let defaultClientID = "b1a00492-073a-47ea-816f-4c329264a828"

    static var file: URL {
        let env = ProcessInfo.processInfo.environment["GROK_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
        return (env ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".grok"))
            .appendingPathComponent("auth.json")
    }

    static var exists: Bool {
        FileManager.default.fileExists(atPath: file.path)
    }

    var isExpiring: Bool {
        let expiry = Self.jwtExpiry(token) ?? expiresAt
        return expiry.map { $0.timeIntervalSinceNow < 5 * 60 } ?? false
    }

    static func load() throws -> GrokCLIAuth {
        guard let data = try? Data(contentsOf: file),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GrokCLIError.notSignedIn
        }

        for (entryKey, value) in object.sorted(by: { $0.key < $1.key }) {
            guard let entry = value as? [String: Any],
                  let token = (entry["key"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !token.isEmpty else { continue }

            let refresh = (entry["refresh_token"] as? String) ?? (entry["refresh"] as? String)
            let suffix = entryKey.components(separatedBy: "::").last?.trimmingCharacters(in: .whitespaces)
            let clientID = (entry["oidc_client_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? (entryKey.contains("::") ? suffix.flatMap { $0.isEmpty ? nil : $0 } : nil)
                ?? defaultClientID
            let expiresAt = ((entry["expires_at"] ?? entry["expires"]) as? String).flatMap(parseDate)

            return GrokCLIAuth(
                entryKey: entryKey,
                token: token,
                refreshToken: refresh.flatMap { $0.isEmpty ? nil : $0 },
                expiresAt: expiresAt,
                clientID: clientID
            )
        }
        throw GrokCLIError.notSignedIn
    }

    /// Updates only this entry's token fields, keeping everything else the CLI saved.
    func save() throws {
        let url = Self.file
        guard let data = try? Data(contentsOf: url),
              var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var entry = object[entryKey] as? [String: Any] else {
            throw GrokCLIError.invalidResponse
        }

        entry["key"] = token
        if let refreshToken { entry["refresh_token"] = refreshToken }
        if let idToken { entry["id_token"] = idToken }
        if let expiresAt {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            entry["expires_at"] = formatter.string(from: expiresAt)
        }
        object[entryKey] = entry

        let output = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try output.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func jwtExpiry(_ token: String) -> Date? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var payload = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = (claims["exp"] as? NSNumber)?.doubleValue else {
            return nil
        }
        return Date(timeIntervalSince1970: exp)
    }

    private static func parseDate(_ raw: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: raw)
            ?? ISO8601DateFormatter().date(from: raw.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression))
    }
}

private nonisolated enum GrokCLIError: LocalizedError {
    case notSignedIn
    case expired
    case teamAccount
    case noWeeklyPool
    case serverError(Int)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .notSignedIn: "The Grok CLI isn’t signed in. Run `grok login`."
        case .expired: "The Grok CLI’s sign-in has expired. Run `grok login` again."
        case .teamAccount: "Grok team accounts have no personal weekly limit."
        case .noWeeklyPool: "This Grok account doesn’t have a weekly usage pool yet."
        case .serverError(let status): "Grok billing request failed (HTTP \(status))."
        case .invalidResponse: "Grok returned billing in an unexpected format."
        }
    }
}

nonisolated enum GrokBotFiles {
    static var secrets: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Grok Bot/sand-secrets.json")
    }
}

private nonisolated enum GrokUsageError: LocalizedError {
    case notSignedIn
    case keychainDenied
    case unreadableToken
    case tokenExpired
    case unauthorized
    case rateLimited
    case serverError(Int)
    case invalidResponse
    case noLimits

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "Grok Bot’s sign-in wasn’t found. Sign in to the Grok Bot app first."
        case .keychainDenied:
            return "ousage needs Keychain access to “Grok Bot Safe Storage” to read Grok Bot’s sign-in."
        case .unreadableToken:
            return "Grok Bot’s saved sign-in couldn’t be read."
        case .tokenExpired:
            return "Grok Bot’s sign-in has expired. Open Grok Bot to refresh it."
        case .unauthorized:
            return "Grok Bot’s token was rejected. Open Grok Bot to sign in again."
        case .rateLimited:
            return "Grok Bot is rate limiting usage checks. Trying again shortly."
        case .serverError(let status):
            return "Grok Bot usage request failed (HTTP \(status))."
        case .invalidResponse:
            return "Grok Bot returned usage in an unexpected format."
        case .noLimits:
            return "Grok Bot didn’t report a weekly usage limit."
        }
    }
}
