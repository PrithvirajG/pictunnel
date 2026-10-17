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

    private var token: String?
    private var inflight: Task<RefreshOutcome, Never>?
    /// A rotated refresh token the store failed to persist; used until a save succeeds, so the
    /// next refresh never presents the stale one (which would count as reuse after 30 s).
    private var unsavedRefreshToken: String?

    public init(store: CredentialStore, http: EngineHTTP, endpoints: Endpoints,
                onNeedsRepair: (@Sendable () -> Void)? = nil) {
        self.store = store
        self.http = http
        self.endpoints = endpoints
        self.onNeedsRepair = onNeedsRepair
    }

    public func setOnNeedsRepair(_ handler: (@Sendable () -> Void)?) {
        onNeedsRepair = handler
    }

    /// The cached access token, refreshing first when there is none.
    public func accessToken() async throws -> String {
        if let token { return token }
        switch await refresh() {
        case .refreshed:
            if let token { return token }
            return try await accessToken()
        case .needsRepair:
            throw AuthError.needsRepair
        case let .transient(raw):
            throw AuthError.transient(raw)
        }
    }

    /// Call after a `401` on a request sent with `failedToken`.
    public func onUnauthorized(failedToken: String? = nil) async -> RefreshOutcome {
        if let failedToken, let token, token != failedToken { return .refreshed }
        if failedToken != nil, token == failedToken { token = nil }
        return await refresh()
    }

    /// Forgets the access token (for example after re-pairing).
    public func reset() {
        token = nil
        unsavedRefreshToken = nil
    }

    private func refresh() async -> RefreshOutcome {
        if let inflight { return await inflight.value }
        let task = Task { await self.performRefresh() }
        inflight = task
        return await task.value
    }

    private func performRefresh() async -> RefreshOutcome {
        defer { inflight = nil }
        guard var creds = try? store.load() else {
            token = nil
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

        if raw.isSuccess {
            guard let pair = try? JSONDecoder().decode(TokenPair.self, from: data),
                  !pair.accessToken.isEmpty, !pair.refreshToken.isEmpty else {
                return .transient(raw)
            }
            // Persist the rotated refresh token before using the new access token.
            creds.refreshToken = pair.refreshToken
            do {
                try store.save(creds)
                unsavedRefreshToken = nil
            } catch {
                unsavedRefreshToken = pair.refreshToken
            }
            token = pair.accessToken
            return .refreshed
        }

        let decision = Decide.decide(Given(flow: .auth, itemState: nil, lastAction: .refresh), raw)
        if decision.action == .requireRepair {
            try? store.wipe()
            token = nil
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
