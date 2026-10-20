//
//  CursorUsageStore.swift
//  ousage
//

import Combine
import Foundation
import Security
import SQLite3

nonisolated struct CursorUsageSnapshot: Sendable {
    /// Included usage for the billing cycle, as a percentage.
    var total: CodexUsageWindow?
    /// Cursor's own models (Auto, Composer, Cursor Grok).
    var auto: CodexUsageWindow?
    /// Other (named API) models.
    var api: CodexUsageWindow?
    /// On-demand spend in dollars, and its limit when Cursor reports one.
    var onDemandSpent: Double?
    var onDemandLimit: Double?
    var fetchedAt: Date

    var formattedOnDemand: String? {
        guard let onDemandSpent else { return nil }
        let spent = onDemandSpent.formatted(.currency(code: "USD").precision(.fractionLength(2)))
        guard let onDemandLimit, onDemandLimit > 0 else { return spent }
        return "\(spent) / \(onDemandLimit.formatted(.currency(code: "USD").precision(.fractionLength(0))))"
    }
}

@MainActor
final class CursorUsageStore: ObservableObject {
    @Published private(set) var snapshot: CursorUsageSnapshot?
    @Published private(set) var isRefreshing = false
    @Published private(set) var message: String?
    @Published private(set) var plan: String?

    private let client = CursorUsageClient()
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

    private func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            let fetched = try await client.fetch()
            snapshot = fetched.snapshot
            plan = fetched.plan ?? plan
            message = nil
        } catch {
            message = error.localizedDescription
        }
    }
}

/// The Connect RPC endpoints Cursor's own dashboard uses, authenticated with the login that the
/// Cursor app (`state.vscdb`) or the Cursor CLI (`cursor-agent login`, Keychain) already saved.
private actor CursorUsageClient {
    private static let base = "https://api2.cursor.sh"
    private static let clientID = "KbZUR41cY7W6zRSdpSUJ7I7mLYBKOCmB"

    /// Refreshed access tokens are kept in memory only, so Cursor's own login is never rewritten.
    private var refreshedToken: (forRefreshToken: String, token: String)?

    func fetch() async throws -> (snapshot: CursorUsageSnapshot, plan: String?) {
        guard let auth = await CursorAuth.load() else { throw CursorUsageError.notSignedIn }

        var token = auth.accessToken
        if let refreshed = refreshedToken, refreshed.forRefreshToken == auth.refreshToken,
           !CursorAuth.isExpiring(refreshed.token) {
            token = refreshed.token
        } else if token.map(CursorAuth.isExpiring) ?? true {
            // A failed refresh only matters when there's no access token left to try.
            do {
                token = try await refresh(auth) ?? token
            } catch where token != nil {}
        }
        guard var token else { throw CursorUsageError.notSignedIn }

        var (data, status) = try await post("aiserver.v1.DashboardService/GetCurrentPeriodUsage", token: token)
        if status == 401 || status == 403, let refreshed = try await refresh(auth) {
            token = refreshed
            (data, status) = try await post("aiserver.v1.DashboardService/GetCurrentPeriodUsage", token: token)
        }
        try Self.check(status)

        guard let usage = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CursorUsageError.invalidResponse
        }
        let snapshot = try Self.parseUsage(usage)
        let plan = await planName(token: token) ?? auth.membershipType.map(Self.displayPlan)
        return (snapshot, plan)
    }

    private func planName(token: String) async -> String? {
        guard let (data, status) = try? await post("aiserver.v1.DashboardService/GetPlanInfo", token: token),
              (200..<300).contains(status),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let info = object["planInfo"] as? [String: Any],
              let name = (info["planName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else {
            return nil
        }
        return name
    }

    private func refresh(_ auth: CursorAuth) async throws -> String? {
        guard let refreshToken = auth.refreshToken, let url = URL(string: "\(Self.base)/oauth/token") else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "client_id": Self.clientID,
            "refresh_token": refreshToken,
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        if object?["shouldLogout"] as? Bool == true { throw CursorUsageError.sessionExpired }
        if status == 400 || status == 401 { throw CursorUsageError.sessionExpired }
        guard (200..<300).contains(status),
              let token = (object?["access_token"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else {
            return nil
        }
        refreshedToken = (refreshToken, token)
        return token
    }

    private func post(_ path: String, token: String) async throws -> (Data, Int) {
        guard let url = URL(string: "\(Self.base)/\(path)") else { throw CursorUsageError.invalidResponse }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.httpBody = Data("{}".utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    private static func check(_ status: Int) throws {
        switch status {
        case 200..<300: return
        case 401, 403: throw CursorUsageError.unauthorized
        case 429: throw CursorUsageError.rateLimited
        default: throw CursorUsageError.serverError(status)
        }
    }

    private static func parseUsage(_ usage: [String: Any]) throws -> CursorUsageSnapshot {
        guard usage["enabled"] as? Bool != false,
              let planUsage = usage["planUsage"] as? [String: Any] else {
            throw CursorUsageError.noSubscription
        }

        let cycleStart = number(usage["billingCycleStart"]).map { Date(timeIntervalSince1970: $0 / 1000) }
        let cycleEnd = number(usage["billingCycleEnd"]).map { Date(timeIntervalSince1970: $0 / 1000) }
        let windowMinutes: Double = if let cycleStart, let cycleEnd, cycleEnd > cycleStart {
            cycleEnd.timeIntervalSince(cycleStart) / 60
        } else {
            30 * 24 * 60
        }

        func window(_ percent: Double?) -> CodexUsageWindow? {
            percent.map { CodexUsageWindow(usedPercent: max(0, $0), windowMinutes: windowMinutes, resetsAt: cycleEnd) }
        }

        // Older plans report spend in cents against a cents limit instead of a percentage.
        var totalPercent = number(planUsage["totalPercentUsed"])
        if totalPercent == nil, let limit = number(planUsage["limit"]), limit > 0 {
            let spent = number(planUsage["totalSpend"]) ?? (limit - (number(planUsage["remaining"]) ?? limit))
            totalPercent = spent / limit * 100
        }

        var snapshot = CursorUsageSnapshot(
            total: window(totalPercent),
            auto: window(number(planUsage["autoPercentUsed"])),
            api: window(number(planUsage["apiPercentUsed"])),
            fetchedAt: Date()
        )

        if let spendLimit = usage["spendLimitUsage"] as? [String: Any] {
            let limit = number(spendLimit["individualLimit"]) ?? number(spendLimit["pooledLimit"]) ?? 0
            let remaining = number(spendLimit["individualRemaining"]) ?? number(spendLimit["pooledRemaining"]) ?? 0
            let reported = [spendLimit["individualUsed"], spendLimit["pooledUsed"], spendLimit["totalSpend"]].compactMap(number)
            let spent = reported.first(where: { $0 > 0 }) ?? max(0, limit - remaining)
            if limit > 0 || spent > 0 {
                snapshot.onDemandSpent = spent / 100
                snapshot.onDemandLimit = limit > 0 ? limit / 100 : nil
            }
        }

        guard snapshot.total != nil || snapshot.auto != nil || snapshot.api != nil else {
            throw CursorUsageError.noLimits
        }
        return snapshot
    }

    /// Connect's JSON encodes 64-bit integers as strings.
    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

    private static func displayPlan(_ membership: String) -> String {
        switch membership {
        case "pro_plus": "Pro+"
        case "ultra": "Ultra"
        default: membership.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

/// Cursor's saved login: the desktop app keeps it in its state database, the CLI in the Keychain.
nonisolated struct CursorAuth: Sendable {
    let accessToken: String?
    let refreshToken: String?
    let membershipType: String?

    static var stateDatabase: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
    }

    static let keychainAccessService = "cursor-access-token"
    static let keychainRefreshService = "cursor-refresh-token"

    static func load() async -> CursorAuth? {
        let values = readState(["cursorAuth/accessToken", "cursorAuth/refreshToken", "cursorAuth/stripeMembershipType"])
        let access = values["cursorAuth/accessToken"]
        let refresh = values["cursorAuth/refreshToken"]
        if access != nil || refresh != nil {
            return CursorAuth(accessToken: access, refreshToken: refresh, membershipType: values["cursorAuth/stripeMembershipType"]?.lowercased())
        }

        // Going through `/usr/bin/security` matches how the Cursor CLI writes these items, so no prompt appears.
        let keychainAccess = await readKeychain(keychainAccessService)
        let keychainRefresh = await readKeychain(keychainRefreshService)
        guard keychainAccess != nil || keychainRefresh != nil else { return nil }
        return CursorAuth(accessToken: keychainAccess, refreshToken: keychainRefresh, membershipType: nil)
    }

    /// Checks for a login without reading any secrets.
    static func exists() -> Bool {
        if FileManager.default.fileExists(atPath: stateDatabase.path),
           readState(["cursorAuth/refreshToken"]).isEmpty == false {
            return true
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainRefreshService,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    static func isExpiring(_ token: String) -> Bool {
        guard let exp = jwtExpiry(token) else { return false }
        return exp.timeIntervalSinceNow < 5 * 60
    }

    private static func jwtExpiry(_ token: String) -> Date? {
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

    /// Read-only, so a running Cursor keeps its lock on the database.
    private static func readState(_ keys: [String]) -> [String: String] {
        var db: OpaquePointer?
        let uri = "file:\(stateDatabase.path)?mode=ro"
        guard FileManager.default.fileExists(atPath: stateDatabase.path),
              sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return [:]
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 1000)

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT value FROM ItemTable WHERE key = ? LIMIT 1", -1, &statement, nil) == SQLITE_OK else {
            return [:]
        }
        defer { sqlite3_finalize(statement) }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        var values: [String: String] = [:]
        for key in keys {
            sqlite3_reset(statement)
            sqlite3_bind_text(statement, 1, key, -1, transient)
            if sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) {
                let value = String(cString: text).trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { values[key] = value }
            }
        }
        return values
    }

    private static func readKeychain(_ service: String) async -> String? {
        await withCheckedContinuation { continuation in
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
            process.arguments = ["find-generic-password", "-s", service, "-w"]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice

            process.terminationHandler = { process in
                let data = output.fileHandleForReading.readDataToEndOfFile()
                let value = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.resume(returning: process.terminationStatus == 0 && value?.isEmpty == false ? value : nil)
            }

            do {
                try process.run()
            } catch {
                continuation.resume(returning: nil)
            }
        }
    }
}

private nonisolated enum CursorUsageError: LocalizedError {
    case notSignedIn
    case sessionExpired
    case unauthorized
    case rateLimited
    case serverError(Int)
    case invalidResponse
    case noSubscription
    case noLimits

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "Cursor’s sign-in wasn’t found. Sign in to Cursor or run `cursor-agent login`."
        case .sessionExpired:
            return "Cursor’s session has expired. Sign in to Cursor or run `cursor-agent login` again."
        case .unauthorized:
            return "Cursor rejected the saved token. Sign in to Cursor again."
        case .rateLimited:
            return "Cursor is rate limiting usage checks. Trying again shortly."
        case .serverError(let status):
            return "Cursor usage request failed (HTTP \(status))."
        case .invalidResponse:
            return "Cursor returned usage in an unexpected format."
        case .noSubscription:
            return "No active Cursor subscription."
        case .noLimits:
            return "Cursor didn’t report any usage limits."
        }
    }
}
