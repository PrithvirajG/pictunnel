import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// `GET /api/v1/server/info` (P§11.1). Unknown fields are ignored.
public struct ServerInfo: Decodable, Equatable, Sendable {
    public struct Upload: Decodable, Equatable, Sendable {
        public static let defaultChunkBytes: Int64 = 8_388_608

        public var tusVersion: String = "1.0.0"
        public var maxFileBytes: Int64?
        public var recommendedChunkBytes: Int64 = Upload.defaultChunkBytes

        public init() {}

        enum CodingKeys: String, CodingKey {
            case tusVersion = "tus_version"
            case maxFileBytes = "max_file_bytes"
            case recommendedChunkBytes = "recommended_chunk_bytes"
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            tusVersion = (try? c.decodeIfPresent(String.self, forKey: .tusVersion)) ?? "1.0.0"
            maxFileBytes = try? c.decodeIfPresent(Int64.self, forKey: .maxFileBytes)
            recommendedChunkBytes = (try? c.decodeIfPresent(Int64.self, forKey: .recommendedChunkBytes)) ?? Upload.defaultChunkBytes
        }
    }

    public var serverId: String
    public var name: String?
    public var version: String?
    public var apiVersion: String?
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
        name = try? c.decodeIfPresent(String.self, forKey: .name)
        version = try? c.decodeIfPresent(String.self, forKey: .version)
        apiVersion = try? c.decodeIfPresent(String.self, forKey: .apiVersion)
        minClientVersion = (try? c.decodeIfPresent([String: String].self, forKey: .minClientVersion)) ?? [:]
        capabilities = (try? c.decodeIfPresent([String].self, forKey: .capabilities)) ?? []
        upload = (try? c.decodeIfPresent(Upload.self, forKey: .upload)) ?? Upload()
        time = try? c.decodeIfPresent(String.self, forKey: .time)
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
    /// `TusRequests`) with the bearer token, through endpoint fallback. The URL must be relative or
    /// on one of the paired endpoints: the token is never sent to another host.
    public func perform(_ request: URLRequest) async -> Outcome<Data> {
        guard let url = request.url else { return .fail(ServerOutcome(transport: .reset)) }
        guard let path = endpoints.relativize(url.absoluteString) else {
            return .fail(ServerOutcome(transport: .reset), .foreignHost(url.host ?? ""))
        }
        return await authorized(path: path) { target in
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
    /// A `401 refresh_token_reused` is returned as is (refreshing cannot help).
    func authorized(path: String, _ build: (URL) -> URLRequest) async -> Outcome<Data> {
        var retried = false
        while true {
            let token: String
            do {
                token = try await auth.accessToken()
            } catch let AuthError.transient(raw) {
                return .fail(raw, .refreshFailed)
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
                (data, resp) = try await endpoints.execute(http, path: path, withAuth)
            } catch {
                return .fail(ServerOutcome(error: error), Self.failure(error))
            }

            let raw = ServerOutcome(response: resp, data: data)
            if resp.statusCode == 401, !retried, raw.problem?.code != "refresh_token_reused" {
                retried = true
                switch await auth.onUnauthorized(failedToken: token) {
                case .refreshed: continue
                case let .needsRepair(r): return .fail(r ?? Self.repairOutcome, .needsRepair)
                case let .transient(r): return .fail(r, .refreshFailed)
                }
            }
            return raw.isSuccess ? .ok(data, raw: raw) : .fail(raw)
        }
    }

    static func failure(_ error: Error) -> NetFailure? {
        if case let .allFailed(_, host?) = error as? EndpointsError { return .tlsRejected(host: host) }
        return nil
    }
}

extension ServerClient {
    /// `DELETE /api/v1/tombstones/{sha256}`: "back up again" (P§7.7). `204` removed it; `404` means
    /// there was none.
    public func deleteTombstone(_ sha256: String) async -> ServerOutcome {
        await authorized(path: "/api/v1/tombstones/\(sha256)") { url in
            var r = URLRequest(url: url)
            r.httpMethod = "DELETE"
            return r
        }.raw
    }

    /// Call on a network change: the LAN endpoint gets another chance first (R9).
    public func onNetworkChanged() { endpoints.resetToPreferred() }
}
