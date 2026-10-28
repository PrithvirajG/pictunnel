import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A pairing failure. `code` is what the Flutter pairing screens key their copy on (it becomes the
/// `PlatformException.code`): a P§10.3 URI error, a server problem code (`pairing_code_invalid`,
/// `rate_limited`, `client_too_old`, …), or one of the transport codes below.
public struct PairingError: Error, Equatable, Sendable {
    /// The certificate failed the pinning rule (P§6.3): it is not the one the QR code or the
    /// trust-on-first-use check named.
    public static let pinMismatch = "pin_mismatch"
    /// No endpoint answered.
    public static let unreachable = "unreachable"
    /// The phone has no network at all.
    public static let offline = "offline"
    /// The server paired, but as a different server than the QR code named.
    public static let serverIdMismatch = "server_id_mismatch"
    /// The redeem answer could not be read.
    public static let badResponse = "bad_response"

    public let code: String
    public let message: String

    public init(_ code: String, _ message: String = "") {
        self.code = code
        self.message = message
    }
}

/// What pairing starts from (the Pigeon `PairRequest`): a scanned QR URI, or manual setup with a
/// URL, the code and the fingerprint the user confirmed (trust on first use, P§6.3 step 5).
public struct PairInput: Equatable, Sendable {
    public var qrUri: String?
    public var serverUrl: String?
    public var code: String?
    public var deviceName: String
    public var pinnedFp: String?

    public init(qrUri: String? = nil, serverUrl: String? = nil, code: String? = nil, deviceName: String,
                pinnedFp: String? = nil) {
        self.qrUri = qrUri
        self.serverUrl = serverUrl
        self.code = code
        self.deviceName = deviceName
        self.pinnedFp = pinnedFp
    }
}

/// A successful pairing; the credentials are already stored.
public struct Paired: Equatable, Sendable {
    public var serverId: String
    public var serverName: String
    public var userName: String
    public var deviceId: String
}

/// Redeems a pairing code (P§6.3) over the endpoints with the pinning rule, then stores the server
/// id, the endpoints (in preference order), the pin, the refresh token and the device id. The
/// redeem's access token is not kept: `AuthManager` refreshes on first use, as on Android.
public struct Pairer: Sendable {
    public static let redeemPath = "/api/v1/pairing/redeem"
    public static let platform = "ios"

    private let store: CredentialStore
    private let appVersion: String
    private let makeHTTP: @Sendable (PinningDelegate) -> EngineHTTP

    /// `makeHTTP` builds the transport whose TLS goes through the given pinning delegate (on the
    /// device: `EngineHTTP(session: EngineHTTP.makeSession(pinning:clientHeader:), ...)`).
    public init(store: CredentialStore, appVersion: String, makeHTTP: @escaping @Sendable (PinningDelegate) -> EngineHTTP) {
        self.store = store
        self.appVersion = appVersion
        self.makeHTTP = makeHTTP
    }

    /// Where and how to pair, validated before anything is sent.
    struct Target: Equatable {
        var serverId: String?
        var endpoints: [String]
        var pin: String
        var code: String
    }

    static func target(_ input: PairInput) throws -> Target {
        if let qr = input.qrUri, !qr.isEmpty {
            switch PairURI.parse(qr) {
            case let .success(info):
                return Target(serverId: info.serverId, endpoints: info.endpoints, pin: info.fingerprint, code: info.code)
            case let .failure(e):
                throw PairingError(e.rawValue)
            }
        }
        guard let url = input.serverUrl?.trimmingCharacters(in: .whitespaces), !url.isEmpty else {
            throw PairingError(PairURIError.missingEndpoint.rawValue)
        }
        guard url.lowercased().hasPrefix("https://") else { throw PairingError(PairURIError.insecureEndpoint.rawValue) }
        let code = (input.code ?? "").trimmingCharacters(in: .whitespaces).uppercased()
        guard PairURI.isValidCode(code) else { throw PairingError(PairURIError.invalidCode.rawValue) }
        guard let fp = input.pinnedFp?.trimmingCharacters(in: .whitespaces), !fp.isEmpty else {
            throw PairingError(PairURIError.missingFingerprint.rawValue)
        }
        return Target(serverId: nil, endpoints: [url], pin: fp, code: code)
    }

    public func pair(_ input: PairInput) async throws -> Paired {
        let t = try Self.target(input)
        let pin = t.pin
        let http = makeHTTP(PinningDelegate(pin: { pin }))
        defer { http.session.finishTasksAndInvalidate() }
        let endpoints = Endpoints(t.endpoints)
        guard !endpoints.urls.isEmpty else { throw PairingError(PairURIError.missingEndpoint.rawValue) }

        let body = try JSONEncoder().encode(RedeemRequest(
            code: t.code, device: .init(deviceName: input.deviceName, platform: Self.platform, appVersion: appVersion)))
        let data: Data
        let resp: HTTPURLResponse
        do {
            (data, resp) = try await endpoints.execute(http, path: Self.redeemPath) { url in
                var r = URLRequest(url: url)
                r.httpMethod = "POST"
                r.setValue("application/json", forHTTPHeaderField: "Content-Type")
                r.httpBody = body
                return r
            }
        } catch {
            throw Self.transportError(error)
        }
        let raw = ServerOutcome(response: resp, data: data)
        guard resp.statusCode == 201 || resp.statusCode == 200 else {
            let p = raw.problem
            throw PairingError(p?.code ?? "http_\(resp.statusCode)", p?.detail ?? p?.title ?? "")
        }
        guard let r = try? JSONDecoder().decode(RedeemResponse.self, from: data) else {
            throw PairingError(PairingError.badResponse)
        }
        if let sid = t.serverId, sid != r.serverId { throw PairingError(PairingError.serverIdMismatch) }

        // The redeem already proved the endpoint answers with an accepted certificate; the name is
        // only for display, so a failure here does not undo the pairing.
        var name = "PicTunnel"
        if let res = try? await endpoints.execute(http, path: "/api/v1/server/info", { URLRequest(url: $0) }),
           (200...299).contains(res.1.statusCode),
           let s = try? JSONDecoder().decode(ServerInfo.self, from: res.0), let n = s.name, !n.isEmpty {
            name = n
        }
        do {
            try store.save(Credentials(serverId: r.serverId, endpoints: t.endpoints, pinSpki: t.pin,
                                       refreshToken: r.tokens.refreshToken, deviceId: r.device.id))
        } catch {
            throw PairingError("credentials_unavailable", "\(error)")
        }
        return Paired(serverId: r.serverId, serverName: name, userName: r.user.username, deviceId: r.device.id)
    }

    /// No HTTP answer: a refused certificate is `pin_mismatch`, no network `offline`, anything
    /// else `unreachable`.
    static func transportError(_ error: Error) -> PairingError {
        var failure = error as? TransportFailure
        if case let .allFailed(last, tlsHost) = error as? EndpointsError {
            if tlsHost != nil { return PairingError(PairingError.pinMismatch) }
            failure = last as? TransportFailure
        }
        if let f = failure {
            if f.isTLS { return PairingError(PairingError.pinMismatch) }
            if offlineCodes.contains(f.code) { return PairingError(PairingError.offline) }
        }
        return PairingError(PairingError.unreachable)
    }

    static let offlineCodes: Set<URLError.Code> = [.notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff]

    private struct RedeemRequest: Encodable {
        struct Device: Encodable {
            var deviceName: String
            var platform: String
            var appVersion: String

            enum CodingKeys: String, CodingKey {
                case deviceName = "device_name"
                case platform
                case appVersion = "app_version"
            }
        }

        var code: String
        var device: Device
    }

    private struct RedeemResponse: Decodable {
        struct User: Decodable { var username: String }
        struct Device: Decodable { var id: String }
        struct Tokens: Decodable {
            var refreshToken: String
            enum CodingKeys: String, CodingKey { case refreshToken = "refresh_token" }
        }

        var serverId: String
        var user: User
        var device: Device
        var tokens: Tokens

        enum CodingKeys: String, CodingKey {
            case serverId = "server_id"
            case user
            case device
            case tokens
        }
    }
}
