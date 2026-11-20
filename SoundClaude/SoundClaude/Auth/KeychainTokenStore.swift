import Foundation
import Security

enum KeychainError: LocalizedError {
    case unexpectedStatus(OSStatus)
    case invalidData

    var errorDescription: String? {
        switch self {
        case let .unexpectedStatus(status):
            return "Keychain access failed with status \(status)."
        case .invalidData:
            return "The saved SoundCloud session is invalid."
        }
    }
}

/// The active session and the accounts signed out of on this Mac, as separate items,
/// so launch reads only the active one.
struct KeychainTokenStore: Sendable {
    private let service: String
    private static let activeAccount = "website-token"
    private static let savedAccountsAccount = "saved-website-tokens"

    init(service: String = "com.tim.soundclaude.native") {
        self.service = service
    }

    func load() throws -> TokenRecord? {
        try read(TokenRecord.self, account: Self.activeAccount)
    }

    func save(_ token: TokenRecord) throws {
        try write(token, account: Self.activeAccount)
    }

    func delete() throws {
        try remove(account: Self.activeAccount)
    }

    func loadSavedAccounts() throws -> [TokenRecord] {
        try read([TokenRecord].self, account: Self.savedAccountsAccount) ?? []
    }

    func saveSavedAccounts(_ records: [TokenRecord]) throws {
        if records.isEmpty {
            try remove(account: Self.savedAccountsAccount)
        } else {
            try write(records, account: Self.savedAccountsAccount)
        }
    }

    private func read<Value: Decodable>(_ type: Value.Type, account: String) throws -> Value? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
        guard let data = result as? Data else {
            throw KeychainError.invalidData
        }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw KeychainError.invalidData
        }
    }

    private func write<Value: Encodable>(_ value: Value, account: String) throws {
        let data = try JSONEncoder().encode(value)
        let update = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(
            baseQuery(account: account) as CFDictionary,
            update as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(updateStatus)
        }

        var addition = baseQuery(account: account)
        addition[kSecValueData as String] = data
        addition[kSecAttrAccessible as String] =
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(addition as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainError.unexpectedStatus(addStatus)
        }
    }

    private func remove(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
