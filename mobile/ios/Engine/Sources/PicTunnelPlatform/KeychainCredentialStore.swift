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
///
/// Every operation holds one process-wide lock, so `compareAndSave` is atomic against `wipe` and
/// `save` (a late token refresh cannot undo an unpair or overwrite a new pairing).
public final class KeychainCredentialStore: CredentialStore, @unchecked Sendable {
    public static let service = "io.github.prithvirajg.pictunnel.engine"
    private static let account = "credentials"
    private static let lock = NSLock()

    public init() {}

    private var base: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
        ]
    }

    public func load() throws -> Credentials? {
        try locked { try loadUnlocked() }
    }

    public func save(_ c: Credentials) throws {
        try locked { try saveUnlocked(c) }
    }

    public func wipe() throws {
        try locked {
            let status = SecItemDelete(base as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
        }
    }

    public func compareAndSave(expectedRefreshToken: String, _ c: Credentials) throws -> Bool {
        try locked {
            guard try loadUnlocked()?.refreshToken == expectedRefreshToken else { return false }
            try saveUnlocked(c)
            return true
        }
    }

    private func loadUnlocked() throws -> Credentials? {
        var q = base
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = out as? Data else { throw KeychainError(status: status) }
        return try JSONDecoder().decode(Credentials.self, from: data)
    }

    private func saveUnlocked(_ c: Credentials) throws {
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

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        return try body()
    }
}
#endif
