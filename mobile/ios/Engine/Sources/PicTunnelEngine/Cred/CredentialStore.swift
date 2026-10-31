import Foundation

/// What pairing leaves on the device (M§4.4): the server id, the endpoint list in preference order
/// (LAN first, then remote), the TLS pin (base64url SHA-256 of the server's SubjectPublicKeyInfo),
/// the refresh token and this device's id. The access token is never persisted.
public struct Credentials: Codable, Equatable, Sendable {
    public var serverId: String
    public var endpoints: [String]
    public var pinSpki: String
    public var refreshToken: String
    public var deviceId: String

    public init(serverId: String, endpoints: [String], pinSpki: String, refreshToken: String, deviceId: String) {
        self.serverId = serverId
        self.endpoints = endpoints
        self.pinSpki = pinSpki
        self.refreshToken = refreshToken
        self.deviceId = deviceId
    }
}

/// Durable credential storage. The iOS implementation is the Keychain with
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` (Task 14); tests use `InMemoryCredentialStore`.
public protocol CredentialStore: Sendable {
    func load() throws -> Credentials?
    func save(_ c: Credentials) throws
    func wipe() throws
    /// Saves `c` only if the stored refresh token is still `expectedRefreshToken` (nothing was
    /// wiped or re-paired meanwhile); false when nothing was saved. A rotated token from a refresh
    /// that raced an unpair or a new pairing must never bring the old credentials back.
    func compareAndSave(expectedRefreshToken: String, _ c: Credentials) throws -> Bool
}

extension CredentialStore {
    /// Compare, then save; stores that can lock override it to make the pair atomic.
    public func compareAndSave(expectedRefreshToken: String, _ c: Credentials) throws -> Bool {
        guard try load()?.refreshToken == expectedRefreshToken else { return false }
        try save(c)
        return true
    }
}

/// A thread-safe in-memory `CredentialStore` for tests and Linux.
public final class InMemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var _creds: Credentials?
    private var _wipes = 0
    private var _saved: [Credentials] = []

    public init(_ creds: Credentials? = nil) {
        _creds = creds
    }

    public var creds: Credentials? { locked { _creds } }
    /// How many times `wipe()` ran.
    public var wipes: Int { locked { _wipes } }
    /// Every value passed to `save(_:)`, in order.
    public var saved: [Credentials] { locked { _saved } }

    public func load() throws -> Credentials? { locked { _creds } }

    public func save(_ c: Credentials) throws {
        locked {
            _saved.append(c)
            _creds = c
        }
    }

    public func wipe() throws {
        locked {
            _wipes += 1
            _creds = nil
        }
    }

    public func compareAndSave(expectedRefreshToken: String, _ c: Credentials) throws -> Bool {
        locked {
            guard _creds?.refreshToken == expectedRefreshToken else { return false }
            _saved.append(c)
            _creds = c
            return true
        }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
