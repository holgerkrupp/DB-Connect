import Foundation
import Security

/// Device-local Keychain cache for Vault auth tokens. Vault tokens are not iCloud-synchronizable:
/// another device should establish its own OIDC session for the same server and mount.
nonisolated struct VaultTokenKeychainStore: VaultTokenStore {
    private let service: String

    init(service: String = "de.holgerkrupp.DB-Connect.vault-token") {
        self.service = service
    }

    private func baseQuery(for scope: VaultTokenScope) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: scope.keychainAccount
        ]
    }

    func save(_ token: VaultToken, for scope: VaultTokenScope) throws {
        let data = try JSONEncoder().encode(token)
        SecItemDelete(baseQuery(for: scope) as CFDictionary)

        var attributes = baseQuery(for: scope)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        attributes[kSecValueData as String] = data
        attributes[kSecAttrLabel as String] = "DB Connect Vault token"

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw VaultTokenKeychainError.writeFailed(status) }
    }

    func token(for scope: VaultTokenScope) throws -> VaultToken? {
        var query = baseQuery(for: scope)
        query[kSecReturnData as String] = kCFBooleanTrue!
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return nil }
            do {
                return try JSONDecoder().decode(VaultToken.self, from: data)
            } catch {
                throw VaultTokenKeychainError.readFailed(errSecDecode)
            }
        case errSecItemNotFound:
            return nil
        default:
            throw VaultTokenKeychainError.readFailed(status)
        }
    }

    func removeToken(for scope: VaultTokenScope) throws {
        let status = SecItemDelete(baseQuery(for: scope) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw VaultTokenKeychainError.deleteFailed(status)
        }
    }
}

nonisolated enum VaultTokenKeychainError: Error, Sendable, Equatable, LocalizedError {
    case writeFailed(OSStatus)
    case readFailed(OSStatus)
    case deleteFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .writeFailed(let status): "Could not save the Vault token (Keychain error \(status))."
        case .readFailed(let status): "Could not read the Vault token (Keychain error \(status))."
        case .deleteFailed(let status): "Could not delete the Vault token (Keychain error \(status))."
        }
    }
}
