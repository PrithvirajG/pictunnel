import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The engine's HTTP transport: a URLSession plus the `PicTunnel-Client` header that every engine
/// request carries (P§3 version gate, M§4.2).
public struct EngineHTTP: @unchecked Sendable {
    public static let clientHeaderName = "PicTunnel-Client"

    public let session: URLSession
    /// `ios/<app version>`.
    public let clientHeader: String

    public init(session: URLSession, clientHeader: String) {
        self.session = session
        self.clientHeader = clientHeader
    }

    public static func clientHeader(version: String) -> String { "ios/\(version)" }

    /// A foreground session for JSON calls whose TLS goes through `pinning` (P§6.3). The client
    /// header is also set on the configuration so tasks created elsewhere on it carry it too.
    public static func makeSession(pinning: PinningDelegate?, clientHeader: String,
                                   configuration: URLSessionConfiguration = .ephemeral) -> URLSession {
        var extra = configuration.httpAdditionalHeaders ?? [:]
        extra[clientHeaderName] = clientHeader
        configuration.httpAdditionalHeaders = extra
        return URLSession(configuration: configuration, delegate: pinning, delegateQueue: nil)
    }

    /// Sends one request; throws the transport error when there is no HTTP response.
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var req = request
        req.setValue(clientHeader, forHTTPHeaderField: Self.clientHeaderName)
        let session = self.session
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(Data, HTTPURLResponse), Error>) in
            session.dataTask(with: req) { data, response, error in
                if let error {
                    cont.resume(throwing: error)
                } else if let http = response as? HTTPURLResponse {
                    cont.resume(returning: (data ?? Data(), http))
                } else {
                    cont.resume(throwing: URLError(.badServerResponse))
                }
            }.resume()
        }
    }
}

/// `GET /api/v1/server/info` (P§11.1). Unknown fields are ignored.
public struct ServerInfo: Decodable, Equatable, Sendable {
    public struct Upload: Decodable, Equatable, Sendable {
        public var tusVersion: String
        public var maxFileBytes: Int64
        public var recommendedChunkBytes: Int64

        enum CodingKeys: String, CodingKey {
            case tusVersion = "tus_version"
            case maxFileBytes = "max_file_bytes"
            case recommendedChunkBytes = "recommended_chunk_bytes"
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            tusVersion = try c.decodeIfPresent(String.self, forKey: .tusVersion) ?? "1.0.0"
            maxFileBytes = try c.decode(Int64.self, forKey: .maxFileBytes)
            recommendedChunkBytes = try c.decodeIfPresent(Int64.self, forKey: .recommendedChunkBytes) ?? 8_388_608
        }
    }

    public var serverId: String
    public var name: String
    public var version: String
    public var apiVersion: String
    /// Per platform (`android`, `ios`, `web`).
    public var minClientVersion: [String: String]
    public var capabilities: [String]
    public var upload: Upload
    public var time: String?

    enum CodingKeys: String, CodingKey {
        case serverId = "server_id"
        case name
        case version
        case apiVersion = "api_version"
        case minClientVersion = "min_client_version"
        case capabilities
        case upload
        case time
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        serverId = try c.decode(String.self, forKey: .serverId)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        version = try c.decodeIfPresent(String.self, forKey: .version) ?? ""
        apiVersion = try c.decodeIfPresent(String.self, forKey: .apiVersion) ?? ""
        minClientVersion = try c.decodeIfPresent([String: String].self, forKey: .minClientVersion) ?? [:]
        capabilities = try c.decodeIfPresent([String].self, forKey: .capabilities) ?? []
        upload = try c.decode(Upload.self, forKey: .upload)
        time = try c.decodeIfPresent(String.self, forKey: .time)
    }
}

/// The engine's JSON client (M§4.2–M§4.4): endpoint fallback, the client header, bearer auth with
/// one refresh-and-retry on `401` (R11), and outcomes ready for `Decide.decide`.
public struct ServerClient: Sendable {
    public let endpoints: Endpoints
    public let auth: AuthManager
    public let http: EngineHTTP

    public init(endpoints: Endpoints, auth: AuthManager, http: EngineHTTP) {
        self.endpoints = endpoints
        self.auth = auth
        self.http = http
    }

    /// Public and exempt from the version gate (P§3). Throws `ServerError` on a non-2xx answer and
    /// the transport error when no endpoint answers.
    public func serverInfo() async throws -> ServerInfo {
        let (data, resp) = try await endpoints.execute(http, path: "/api/v1/server/info") { URLRequest(url: $0) }
        let raw = ServerOutcome(response: resp, data: data)
        guard raw.isSuccess else { throw ServerError(raw) }
        do {
            return try JSONDecoder().decode(ServerInfo.self, from: data)
        } catch {
            throw ServerError(raw)
        }
    }

    /// Sends an engine request built elsewhere (for example a tus HEAD, PATCH or DELETE from
    /// `TusRequests`) with the bearer token. A URL on one of our endpoints, or a relative one, is
    /// replayed through endpoint fallback; a foreign URL is sent as is.
    public func perform(_ request: URLRequest) async -> Outcome<Data> {
        guard let url = request.url else { return .fail(ServerOutcome(transport: .reset)) }
        let path = endpoints.relativize(url.absoluteString)
        return await authorized(path: path, absolute: url) { target in
            var r = request
            r.url = target
            return r
        }
    }

    /// The synthetic outcome for "credentials are gone": `decide()` maps it to `require_repair`.
    static let repairOutcome = ServerOutcome(status: 401, body: .object([
        "type": .string(Problem.typePrefix + "refresh_token_reused"),
        "status": .number(401),
        "code": .string("refresh_token_reused"),
    ]))

    /// Runs one authorized request: on `401` it refreshes once (single-flight) and retries.
    func authorized(path: String?, absolute: URL? = nil,
                    _ build: (URL) -> URLRequest) async -> Outcome<Data> {
        var retried = false
        while true {
            let token: String
            do {
                token = try await auth.accessToken()
            } catch let AuthError.transient(raw) {
                return .fail(raw)
            } catch {
                return .fail(Self.repairOutcome, .needsRepair)
            }

            let data: Data
            let resp: HTTPURLResponse
            do {
                func withAuth(_ url: URL) -> URLRequest {
                    var r = build(url)
                    r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                    return r
                }
                if let path {
                    (data, resp) = try await endpoints.execute(http, path: path, withAuth)
                } else if let absolute {
                    (data, resp) = try await http.send(withAuth(absolute))
                } else {
                    return .fail(ServerOutcome(transport: .reset))
                }
            } catch {
                return .fail(ServerOutcome(error: error), Self.failure(error))
            }

            let raw = ServerOutcome(response: resp, data: data)
            if resp.statusCode == 401, !retried {
                retried = true
                switch await auth.onUnauthorized(failedToken: token) {
                case .refreshed: continue
                case let .needsRepair(r): return .fail(r ?? Self.repairOutcome, .needsRepair)
                case let .transient(r): return .fail(r)
                }
            }
            return raw.isSuccess ? .ok(data, raw: raw) : .fail(raw)
        }
    }

    static func failure(_ error: Error) -> NetFailure? {
        if case let .allFailed(_, _, host?) = error as? EndpointsError { return .tlsRejected(host: host) }
        return nil
    }
}
