import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// What a refresh came to.
public enum RefreshOutcome: Equatable, Sendable {
    /// A fresh access token is cached (or another caller already replaced the failed one).
    case refreshed
    /// The refresh token was reused or the device revoked (`401`/`403`), or there are no
    /// credentials: they are wiped and `onNeedsRepair` fired. `raw` is nil without a request.
    case needsRepair(ServerOutcome?)
    /// Network failure or a server-side error: the tokens are kept, try again later (M§4.4).
    case transient(ServerOutcome)
}

public enum AuthError: Error, Equatable, Sendable {
    case needsRepair
    case transient(ServerOutcome)
}

/// Owns the access token (memory only) and the refresh rotation (P§6.2, R11, M§4.4).
///
/// Refreshes are single-flight: concurrent callers join the one in flight, and a caller whose
/// `401` came from a token that has already been replaced gets `.refreshed` without another
/// request. Refreshes racing from another process rely on the server's 30 s grace window.
public actor AuthManager {
    private let store: CredentialStore
    private let http: EngineHTTP
    private let endpoints: Endpoints
    private var onNeedsRepair: (@Sendable () -> Void)?

    /// Monotonic seconds (default `ProcessInfo.systemUptime`); only schedules the proactive
    /// refresh, so correctness never depends on the device clock (R10).
    private let uptime: @Sendable () -> TimeInterval

    private var token: String?
    /// The uptime after which `token` is refreshed before use.
    private var validUntil: TimeInterval = 0
    private var inflight: Task<RefreshOutcome, Never>?
    /// A rotated refresh token the store failed to persist; used until a save succeeds, so the
    /// next refresh never presents the stale one (which would count as reuse after 30 s).
    private var unsavedRefreshToken: String?
    /// Set by `close`: the session is over (unpaired or replaced by a new pairing).
    private var closed = false

    public init(store: CredentialStore, http: EngineHTTP, endpoints: Endpoints,
                onNeedsRepair: (@Sendable () -> Void)? = nil,
                uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.uptime = uptime
        self.store = store
        self.http = http
        self.endpoints = endpoints
        self.onNeedsRepair = onNeedsRepair
    }

    public func setOnNeedsRepair(_ handler: (@Sendable () -> Void)?) {
        onNeedsRepair = handler
    }

    /// Access tokens live 15 min (P§6.1); refresh a minute early, like the Kotlin engine.
    public static let refreshAfter: TimeInterval = 14 * 60

    /// A valid access token, refreshing first when there is none or it is about to expire.
    public func accessToken() async throws -> String {
        if let token, uptime() < validUntil { return token }
        switch await refresh(stale: token) {
        case .refreshed:
            if let token { return token }
            throw AuthError.transient(ServerOutcome(transport: .reset))
        case .needsRepair:
            throw AuthError.needsRepair
        case let .transient(raw):
            throw AuthError.transient(raw)
        }
    }

    /// Call after a `401` on a request sent with `failedToken`. If another caller already replaced
    /// that token, no second refresh happens. Without it the current token is assumed stale.
    public func onUnauthorized(failedToken: String? = nil) async -> RefreshOutcome {
        await refresh(stale: failedToken ?? token)
    }

    /// Forgets the access token (for example after re-pairing).
    public func reset() {
        token = nil
        validUntil = 0
        unsavedRefreshToken = nil
    }

    /// Ends this session before its credentials are wiped or replaced (unpair, pairing): no refresh
    /// starts after it, the one in flight is cancelled and awaited (so it ends within the time a
    /// cancelled request takes, not its 60 s timeout), and then `block` runs (the wipe). A refresh
    /// answer that still arrives is never saved: `closed` stops it, and the compare-and-save in
    /// `performRefresh` stops one that raced a wipe made outside this lock.
    public func close<T: Sendable>(_ block: @Sendable () throws -> T) async rethrows -> T {
        closed = true
        token = nil
        validUntil = 0
        unsavedRefreshToken = nil
        if let inflight {
            inflight.cancel()
            _ = await inflight.value
        }
        return try block()
    }

    /// True once `close` ran: this session never refreshes again.
    public var isClosed: Bool { closed }

    /// Single flight: callers join the refresh in flight, and a caller whose token was already
    /// replaced by a still-valid one gets `.refreshed` without a request.
    private func refresh(stale: String?) async -> RefreshOutcome {
        if closed { return .needsRepair(nil) }
        if let token, token != stale, uptime() < validUntil { return .refreshed }
        if let inflight { return await inflight.value }
        let task = Task { await self.performRefresh() }
        inflight = task
        return await task.value
    }

    private func performRefresh() async -> RefreshOutcome {
        defer { inflight = nil }
        let loaded: Credentials?
        do {
            loaded = try store.load()
        } catch {
            // Unreadable (e.g. Keychain locked before first unlock) is not "gone": keep everything.
            return .transient(ServerOutcome(transport: .reset))
        }
        guard var creds = loaded else {
            // Nothing stored: already wiped or never paired; do not wipe or notify again.
            token = nil
            validUntil = 0
            return .needsRepair(nil)
        }
        let presented = unsavedRefreshToken ?? creds.refreshToken

        let body: Data
        do {
            body = try JSONEncoder().encode(["refresh_token": presented])
        } catch {
            return .transient(ServerOutcome(transport: .reset))
        }

        let raw: ServerOutcome
        let data: Data
        do {
            let (d, resp) = try await endpoints.execute(http, path: "/api/v1/auth/refresh") { url in
                var r = URLRequest(url: url)
                r.httpMethod = "POST"
                r.setValue("application/json", forHTTPHeaderField: "Content-Type")
                r.httpBody = body
                return r
            }
            raw = ServerOutcome(response: resp, data: d)
            data = d
        } catch {
            return .transient(ServerOutcome(error: error))
        }

        // Closed while the request was out: whatever came back belongs to a session that is over.
        if closed { return .needsRepair(nil) }

        if raw.isSuccess {
            guard let pair = try? JSONDecoder().decode(TokenPair.self, from: data),
                  !pair.accessToken.isEmpty, !pair.refreshToken.isEmpty else {
                return .transient(raw)
            }
            // Persist the rotated refresh token before using the new access token, unless the
            // credentials were wiped or replaced while the refresh was in flight.
            let expected = creds.refreshToken
            creds.refreshToken = pair.refreshToken
            do {
                guard try store.compareAndSave(expectedRefreshToken: expected, creds) else {
                    token = nil
                    validUntil = 0
                    unsavedRefreshToken = nil
                    return .needsRepair(nil)
                }
                unsavedRefreshToken = nil
            } catch {
                unsavedRefreshToken = pair.refreshToken
            }
            token = pair.accessToken
            validUntil = uptime() + Self.refreshAfter
            return .refreshed
        }

        let decision = Decide.decide(Given(flow: .auth, itemState: nil, lastAction: .refresh), raw)
        if decision.action == .requireRepair {
            try? store.wipe()
            token = nil
            validUntil = 0
            unsavedRefreshToken = nil
            onNeedsRepair?()
            return .needsRepair(raw)
        }
        return .transient(raw)
    }

    private struct TokenPair: Decodable {
        let accessToken: String
        let refreshToken: String

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
        }
    }
}
