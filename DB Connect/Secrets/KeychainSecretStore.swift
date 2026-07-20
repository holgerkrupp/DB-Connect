import Foundation
import Security

/// Stores connection secrets as iCloud-synced Keychain items, one generic-password item per
/// connection, keyed by the connection's UUID.
///
/// Design constraints baked in here:
/// - `kSecAttrSynchronizable` makes the item sync via iCloud Keychain. Synchronizable items
///   cannot carry biometric access control — that pair is mutually exclusive in the Security
///   framework — so any Face ID / Touch ID gating happens at the app layer with LocalAuthentication,
///   not down here.
/// - `kSecAttrAccessibleAfterFirstUnlock` is the most restrictive accessibility that still
///   allows background monitor runs and syncing.
/// - The whole `Secret` struct is one JSON payload per item, so adding fields (SSH keys, API
///   tokens) never changes the Keychain schema.
nonisolated struct KeychainSecretStore: Sendable {

    private let service: String

    init(service: String = "de.holgerkrupp.DB-Connect.connection") {
        self.service = service
    }

    private func baseQuery(for connectionID: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: connectionID.uuidString,
            // Matches both synchronizable and legacy local items on read/delete.
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]
    }

    func save(_ secret: Secret, for connectionID: UUID) throws {
        let data = try JSONEncoder().encode(secret)

        // Delete-then-add is simpler and no less atomic than SecItemUpdate for a single item.
        SecItemDelete(baseQuery(for: connectionID) as CFDictionary)

        var attributes = baseQuery(for: connectionID)
        attributes[kSecAttrSynchronizable as String] = kCFBooleanTrue!
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        attributes[kSecValueData as String] = data
        attributes[kSecAttrLabel as String] = "DB Connect"

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.writeFailed(status)
        }
    }

    func secret(for connectionID: UUID) throws -> Secret? {
        var query = baseQuery(for: connectionID)
        query[kSecReturnData as String] = kCFBooleanTrue!
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return nil }
            return try JSONDecoder().decode(Secret.self, from: data)
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.readFailed(status)
        }
    }

    func delete(for connectionID: UUID) throws {
        let status = SecItemDelete(baseQuery(for: connectionID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed(status)
        }
    }
}

nonisolated enum KeychainError: Error, LocalizedError {
    case writeFailed(OSStatus)
    case readFailed(OSStatus)
    case deleteFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .writeFailed(let s): "Could not save the credentials (Keychain error \(s))."
        case .readFailed(let s): "Could not read the credentials (Keychain error \(s))."
        case .deleteFailed(let s): "Could not delete the credentials (Keychain error \(s))."
        }
    }
}
