//
//  OpenCodeUsageStore.swift
//  ousage
//

import Combine
import Foundation

nonisolated enum OpenCodeAPIKeySource: Sendable {
    case keychain
    case authFile
}

nonisolated struct OpenCodeUsageWindowSnapshot: Sendable {
    let usedPercent: Double
    let windowMinutes: Double
    let resetsAt: Date?
    let isRateLimited: Bool

    var usageWindow: CodexUsageWindow {
        CodexUsageWindow(
            usedPercent: isRateLimited ? 100 : usedPercent,
            windowMinutes: windowMinutes,
            resetsAt: resetsAt
        )
    }
}

nonisolated struct OpenCodeUsageSnapshot: Sendable {
    let rolling: OpenCodeUsageWindowSnapshot?
    let weekly: OpenCodeUsageWindowSnapshot?
    let monthly: OpenCodeUsageWindowSnapshot?
    let fetchedAt: Date
}

@MainActor
final class OpenCodeUsageStore: ObservableObject {
    @Published private(set) var snapshot: OpenCodeUsageSnapshot?
    @Published private(set) var isRefreshing = false
    @Published private(set) var isConfigured: Bool
    @Published private(set) var keySource: OpenCodeAPIKeySource?
    @Published private(set) var message: String?

    private let client = OpenCodeUsageClient()

    init() {
        let resolved = OpenCodeAPIKey.resolveIgnoringErrors()
        isConfigured = resolved != nil
        keySource = resolved?.source
    }

    var subtitle: String? {
        guard let fetchedAt = snapshot?.fetchedAt else { return nil }
        let relative = fetchedAt.formatted(.relative(presentation: .named))
        return keySource == .authFile
            ? "Key from OpenCode · updated \(relative)"
            : "Updated \(relative)"
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

    func saveAPIKey(_ value: String) {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            message = "Enter an OpenCode API key."
            return
        }

        Task { [weak self] in
            await self?.validateAndSave(key)
        }
    }

    func removeAPIKey() {
        do {
            try OpenCodeKeychain.delete()
        } catch {
            message = error.localizedDescription
            return
        }

        snapshot = nil
        message = nil

        let resolved = OpenCodeAPIKey.resolveIgnoringErrors()
        isConfigured = resolved != nil
        keySource = resolved?.source

        if resolved != nil {
            refreshNow()
        }
    }

    private func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            guard let resolved = try OpenCodeAPIKey.resolve() else {
                snapshot = nil
                isConfigured = false
                keySource = nil
                message = nil
                return
            }

            keySource = resolved.source
            isConfigured = true

            snapshot = try await client.fetch(apiKey: resolved.key)
            message = nil
        } catch {
            message = error.localizedDescription
        }
    }

    private func validateAndSave(_ key: String) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            let newSnapshot = try await client.fetch(apiKey: key)
            try OpenCodeKeychain.save(key)
            keySource = .keychain
            snapshot = newSnapshot
            isConfigured = true
            message = nil
        } catch {
            message = error.localizedDescription
        }
    }
}

private actor OpenCodeUsageClient {
    func fetch(apiKey: String) async throws -> OpenCodeUsageSnapshot {
        guard let url = URL(string: "https://opencode.ai/zen/go/v1/usage") else {
            throw OpenCodeUsageError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenCodeUsageError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200..<300:
            break
        case 401:
            throw OpenCodeUsageError.unauthorized
        default:
            throw Self.apiError(from: data, statusCode: httpResponse.statusCode)
        }

        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let usage = object["usage"] as? [String: Any] else {
            throw OpenCodeUsageError.invalidResponse
        }

        let rolling = Self.parseWindow(usage["rolling"], windowMinutes: 300)
        let weekly = Self.parseWindow(usage["weekly"], windowMinutes: 10_080)
        let monthly = Self.parseWindow(usage["monthly"], windowMinutes: 0)

        guard rolling != nil || weekly != nil || monthly != nil else {
            throw OpenCodeUsageError.invalidResponse
        }

        return OpenCodeUsageSnapshot(
            rolling: rolling,
            weekly: weekly,
            monthly: monthly,
            fetchedAt: Date()
        )
    }

    private static func parseWindow(_ value: Any?, windowMinutes: Double) -> OpenCodeUsageWindowSnapshot? {
        guard let raw = value as? [String: Any] else { return nil }

        let percent = Self.percent(from: raw)
        guard let percent else { return nil }

        let resetsAt = (raw["resetsAt"] as? String).flatMap(Self.parseISODate)
        let isRateLimited = (raw["status"] as? String) == "rate-limited"

        return OpenCodeUsageWindowSnapshot(
            usedPercent: percent,
            windowMinutes: windowMinutes,
            resetsAt: resetsAt,
            isRateLimited: isRateLimited
        )
    }

    private static func percent(from raw: [String: Any]) -> Double? {
        if let percent = (raw["percent"] as? NSNumber)?.doubleValue {
            return percent
        }
        if let percent = (raw["usagePercent"] as? NSNumber)?.doubleValue {
            return percent
        }
        return nil
    }

    private static func parseISODate(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) {
            return date
        }

        let plain = ISO8601DateFormatter()
        return plain.date(from: raw)
    }

    private static func apiError(from data: Data, statusCode: Int) -> OpenCodeUsageError {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = object["error"] as? [String: Any],
           let message = error["message"] as? String,
           !message.isEmpty {
            return .api(message)
        }
        return .serverError(statusCode)
    }
}

private nonisolated enum OpenCodeAPIKey {
    /// OpenCode's own Go login wins, then a key saved here, then any other OpenCode key.
    static func resolve() throws -> (key: String, source: OpenCodeAPIKeySource)? {
        if let goLogin = OpenCodeAuthFile.key(providerIDs: ["opencode-go"]), !goLogin.isEmpty {
            return (goLogin, .authFile)
        }

        if let manual = try OpenCodeKeychain.read(), !manual.isEmpty {
            return (manual, .keychain)
        }

        if let auto = OpenCodeAuthFile.key(providerIDs: ["opencode"]), !auto.isEmpty {
            return (auto, .authFile)
        }

        return nil
    }

    static func resolveIgnoringErrors() -> (key: String, source: OpenCodeAPIKeySource)? {
        (try? resolve()) ?? nil
    }
}

private nonisolated enum OpenCodeAuthFile {
    /// `$OPENCODE_DATA_DIR`, then `$XDG_DATA_HOME/opencode`, then `~/.local/share/opencode`.
    private static var dataDirectory: URL {
        let env = ProcessInfo.processInfo.environment
        if let dir = env["OPENCODE_DATA_DIR"], !dir.isEmpty { return URL(fileURLWithPath: dir) }
        if let xdg = env["XDG_DATA_HOME"], !xdg.isEmpty { return URL(fileURLWithPath: xdg).appendingPathComponent("opencode") }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/opencode")
    }

    static func key(providerIDs: [String] = ["opencode-go", "opencode"]) -> String? {
        let fileURL = dataDirectory.appendingPathComponent("auth.json")

        guard let data = try? Data(contentsOf: fileURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        for providerID in providerIDs {
            guard let entry = object[providerID] as? [String: Any] else { continue }

            let type = entry["type"] as? String
            if (type == "api" || type == "wellknown"),
               let key = entry["key"] as? String, !key.isEmpty {
                return key
            }

            if type == "oauth",
               let access = entry["access"] as? String, !access.isEmpty {
                return access
            }

            if let key = entry["key"] as? String, !key.isEmpty {
                return key
            }
        }

        return nil
    }
}

private nonisolated enum OpenCodeKeychain {
    private static let service = "com.ojf.ousage.opencode"
    private static let account = "zen-api-key"

    static func read() throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw OpenCodeUsageError.keychain(status)
        }
        guard let data = result as? Data,
              let key = String(data: data, encoding: .utf8) else {
            throw OpenCodeUsageError.invalidStoredKey
        }
        return key
    }

    static func save(_ key: String) throws {
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: Data(key.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]

        let updateStatus = SecItemUpdate(
            baseQuery as CFDictionary,
            attributes as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw OpenCodeUsageError.keychain(updateStatus)
        }

        var newItem = baseQuery
        newItem.merge(attributes) { _, new in new }
        let addStatus = SecItemAdd(newItem as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw OpenCodeUsageError.keychain(addStatus)
        }
    }

    static func delete() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw OpenCodeUsageError.keychain(status)
        }
    }
}

private nonisolated enum OpenCodeUsageError: LocalizedError {
    case invalidURL
    case invalidResponse
    case unauthorized
    case serverError(Int)
    case invalidStoredKey
    case keychain(OSStatus)
    case api(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "The OpenCode usage URL is invalid."
        case .invalidResponse:
            return "OpenCode returned usage in an unexpected format."
        case .unauthorized:
            return "OpenCode rejected this API key."
        case .serverError(let statusCode):
            return "OpenCode returned HTTP \(statusCode)."
        case .invalidStoredKey:
            return "The OpenCode key stored in Keychain could not be read."
        case .keychain(let status):
            let detail = SecCopyErrorMessageString(status, nil) as String?
            return detail.map { "Keychain error: \($0)" } ?? "Keychain error \(status)."
        case .api(let message):
            return message
        }
    }
}
