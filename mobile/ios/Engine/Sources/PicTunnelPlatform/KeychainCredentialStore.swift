#if os(iOS)
import Foundation
import PicTunnelEngine
import Security

public struct KeychainError: Error, Equatable {
    public let status: OSStatus
}

/// `CredentialStore` in the Keychain (M§4.4): one generic-password item holding the credentials as
/// JSON, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, so background runs can read it once
/// the phone was unlocked after boot, and it never leaves the device (no backup, no iCloud).
/// Before the first unlock reading fails with `errSecInteractionNotAllowed`, which the engine
/// treats as transient, never as "unpaired".
public final class KeychainCredentialStore: CredentialStore, @unchecked Sendable {
    public static let service = "io.github.prithvirajg.pictunnel.engine"
    private static let account = "credentials"

    public init() {}

    private var base: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
        ]
    }

    public func load() throws -> Credentials? {
        var q = base
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = out as? Data else { throw KeychainError(status: status) }
        return try JSONDecoder().decode(Credentials.self, from: data)
    }

    public func save(_ c: Credentials) throws {
        let data = try JSONEncoder().encode(c)
        let attrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        var status = SecItemUpdate(base as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            var add = base
            add.merge(attrs) { _, new in new }
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    public func wipe() throws {
        let status = SecItemDelete(base as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}
#endif
