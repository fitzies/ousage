//
//  OpenRouterBalanceStore.swift
//  ousage
//

import Combine
import Foundation
import Security

nonisolated struct OpenRouterBalanceSnapshot: Sendable {
    let balance: Decimal
    let fetchedAt: Date

    var formattedBalance: String {
        balance.formatted(
            .currency(code: "USD")
                .precision(.fractionLength(2))
        )
    }
}

@MainActor
final class OpenRouterBalanceStore: ObservableObject {
    @Published private(set) var snapshot: OpenRouterBalanceSnapshot?
    @Published private(set) var isRefreshing = false
    @Published private(set) var isConfigured: Bool
    @Published private(set) var message: String?

    private let client = OpenRouterBalanceClient()

    init() {
        do {
            isConfigured = try OpenRouterKeychain.read() != nil
        } catch {
            isConfigured = false
            message = error.localizedDescription
        }
    }

    var subtitle: String? {
        guard let fetchedAt = snapshot?.fetchedAt else { return nil }
        return "Updated \(fetchedAt.formatted(.relative(presentation: .named)))"
    }

    func refreshNow() {
        Task { [weak self] in
            await self?.refresh()
        }
    }

    func refreshIfStale() {
        guard isConfigured else { return }
        guard let fetchedAt = snapshot?.fetchedAt,
              Date().timeIntervalSince(fetchedAt) < 30 else {
            refreshNow()
            return
        }
    }

    func saveAPIKey(_ value: String) {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            message = "Enter an OpenRouter management API key."
            return
        }

        Task { [weak self] in
            await self?.validateAndSave(key)
        }
    }

    func removeAPIKey() {
        do {
            try OpenRouterKeychain.delete()
            snapshot = nil
            isConfigured = false
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
            try OpenRouterKeychain.save(key)
            snapshot = newSnapshot
            isConfigured = true
            message = nil
        } catch {
            message = error.localizedDescription
        }
    }

    private func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            guard let key = try OpenRouterKeychain.read() else {
                isConfigured = false
                snapshot = nil
                return
            }

            snapshot = try await client.fetch(apiKey: key)
            isConfigured = true
            message = nil
        } catch {
            message = error.localizedDescription
        }
    }
}

private actor OpenRouterBalanceClient {
    func fetch(apiKey: String) async throws -> OpenRouterBalanceSnapshot {
        guard let url = URL(string: "https://openrouter.ai/api/v1/credits") else {
            throw OpenRouterBalanceError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenRouterBalanceError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200..<300:
            break
        case 401:
            throw OpenRouterBalanceError.unauthorized
        case 403:
            throw OpenRouterBalanceError.managementKeyRequired
        default:
            throw OpenRouterBalanceError.serverError(httpResponse.statusCode)
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        do {
            let response = try decoder.decode(CreditsResponse.self, from: data)
            return OpenRouterBalanceSnapshot(
                balance: response.data.totalCredits - response.data.totalUsage,
                fetchedAt: Date()
            )
        } catch {
            throw OpenRouterBalanceError.invalidResponse
        }
    }

    private struct CreditsResponse: Decodable {
        let data: Credits
    }

    private struct Credits: Decodable {
        let totalCredits: Decimal
        let totalUsage: Decimal
    }
}

private nonisolated enum OpenRouterKeychain {
    private static let service = "com.ojf.ousage.openrouter"
    private static let account = "management-api-key"

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
            throw OpenRouterBalanceError.keychain(status)
        }
        guard let data = result as? Data,
              let key = String(data: data, encoding: .utf8) else {
            throw OpenRouterBalanceError.invalidStoredKey
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
            throw OpenRouterBalanceError.keychain(updateStatus)
        }

        var newItem = baseQuery
        newItem.merge(attributes) { _, new in new }
        let addStatus = SecItemAdd(newItem as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw OpenRouterBalanceError.keychain(addStatus)
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
            throw OpenRouterBalanceError.keychain(status)
        }
    }
}

private nonisolated enum OpenRouterBalanceError: LocalizedError {
    case invalidURL
    case invalidResponse
    case unauthorized
    case managementKeyRequired
    case serverError(Int)
    case invalidStoredKey
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "The OpenRouter credits URL is invalid."
        case .invalidResponse:
            return "OpenRouter returned an unexpected response."
        case .unauthorized:
            return "OpenRouter rejected this API key."
        case .managementKeyRequired:
            return "OpenRouter requires a management API key for credit balance."
        case .serverError(let statusCode):
            return "OpenRouter returned HTTP \(statusCode)."
        case .invalidStoredKey:
            return "The OpenRouter key stored in Keychain could not be read."
        case .keychain(let status):
            let detail = SecCopyErrorMessageString(status, nil) as String?
            return detail.map { "Keychain error: \($0)" } ?? "Keychain error \(status)."
        }
    }
}
