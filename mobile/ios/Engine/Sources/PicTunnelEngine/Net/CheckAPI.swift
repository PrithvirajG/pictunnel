import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One item of `POST /api/v1/sync/check` (P§7.2).
public struct CheckItem: Equatable, Sendable {
    public var sha256: String
    public var sizeBytes: Int64
    public var localId: String?

    public init(sha256: String, sizeBytes: Int64, localId: String? = nil) {
        self.sha256 = sha256
        self.sizeBytes = sizeBytes
        self.localId = localId
    }
}

/// The active upload session of a `partial` verdict.
public struct CheckUpload: Equatable, Sendable {
    public var id: String
    public var url: String
    public var offset: Int64
    public var length: Int64
    public var expiresAt: String?

    public init(id: String, url: String, offset: Int64, length: Int64, expiresAt: String?) {
        self.id = id
        self.url = url
        self.offset = offset
        self.length = length
        self.expiresAt = expiresAt
    }
}

/// One check result. `verdict` stays a string: unknown verdicts are skipped by `decide()` (R7).
public struct CheckResult: Equatable, Sendable {
    public var sha256: String
    public var verdict: String
    public var assetId: String?
    public var assetState: String?
    public var hasLiveVideo: Bool?
    public var onDisk: Bool?
    public var upload: CheckUpload?
    public var deletedAt: String?
    /// The result object as the server sent it.
    public var json: JSONValue

    public init?(_ json: JSONValue) {
        guard case .object = json else { return nil }
        self.json = json
        sha256 = json["sha256"]?.stringValue ?? ""
        verdict = json["verdict"]?.stringValue ?? ""
        assetId = json["asset_id"]?.stringValue
        assetState = json["asset_state"]?.stringValue
        hasLiveVideo = json["has_live_video"]?.boolValue
        onDisk = json["on_disk"]?.boolValue
        deletedAt = json["deleted_at"]?.stringValue
        if let u = json["upload"], let id = u["id"]?.stringValue, let url = u["url"]?.stringValue {
            upload = CheckUpload(id: id, url: url, offset: Int64(u["offset"]?.intValue ?? 0),
                                 length: Int64(u["length"]?.intValue ?? 0), expiresAt: u["expires_at"]?.stringValue)
        }
    }

    /// This result alone as a check outcome, the shape `decide()` takes per item.
    public func outcome(from raw: ServerOutcome) -> ServerOutcome {
        ServerOutcome(status: raw.status, headers: raw.headers, body: .object(["results": .array([json])]))
    }
}

extension ServerClient {
    /// P§7.2 / R6: at most 1000 items per request.
    public static let checkBatchLimit = 1000

    /// `POST /api/v1/sync/check`, in batches of up to 1000, with results in request order.
    /// `confirmOnDisk` asks the server to stat each original (free up space, P§7.8).
    public func check(_ items: [CheckItem], confirmOnDisk: Bool = false) async -> Outcome<[CheckResult]> {
        var all: [CheckResult] = []
        var last = ServerOutcome(status: 200, body: .object(["results": .array([])]))
        var batches = 0
        for start in stride(from: 0, to: items.count, by: Self.checkBatchLimit) {
            let batch = Array(items[start..<min(start + Self.checkBatchLimit, items.count)])
            let body: Data
            do {
                body = try JSONEncoder().encode(CheckRequest(items: batch.map {
                    CheckRequest.Item(sha256: $0.sha256, sizeBytes: $0.sizeBytes, localId: $0.localId,
                                      confirmOnDisk: confirmOnDisk)
                }))
            } catch {
                return .fail(ServerOutcome(transport: .reset))
            }
            let out = await authorized(path: "/api/v1/sync/check") { url in
                var r = URLRequest(url: url)
                r.httpMethod = "POST"
                r.setValue("application/json", forHTTPHeaderField: "Content-Type")
                r.httpBody = body
                return r
            }
            switch out {
            case let .fail(raw, failure):
                return .fail(raw, failure)
            case let .ok(_, raw):
                all += (raw.body?["results"]?.arrayValue ?? []).compactMap(CheckResult.init)
                last = raw
                batches += 1
            }
        }
        if batches <= 1 { return .ok(all, raw: last) }
        // Several batches: one combined outcome, as if the server had answered them together.
        return .ok(all, raw: ServerOutcome(status: last.status, headers: last.headers,
                                           body: .object(["results": .array(all.map(\.json))])))
    }
}

private struct CheckRequest: Encodable {
    struct Item: Encodable {
        let sha256: String
        let sizeBytes: Int64
        let localId: String?
        let confirmOnDisk: Bool

        enum CodingKeys: String, CodingKey {
            case sha256
            case sizeBytes = "size_bytes"
            case localId = "local_id"
            case confirmOnDisk = "confirm_on_disk"
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(sha256, forKey: .sha256)
            try c.encode(sizeBytes, forKey: .sizeBytes)
            try c.encodeIfPresent(localId, forKey: .localId)
            try c.encode(confirmOnDisk, forKey: .confirmOnDisk)
        }
    }

    let items: [Item]
}
