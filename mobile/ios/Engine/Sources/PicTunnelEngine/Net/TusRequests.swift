import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// `Upload-Metadata` fields (P§7.3, M§4.2). Optional fields are omitted when nil.
public struct UploadMeta: Equatable, Sendable {
    public var sha256: String
    public var filename: String
    public var mime: String
    public var localId: String?
    /// RFC 3339.
    public var createdAt: String?
    /// RFC 3339.
    public var modifiedAt: String?
    /// `primary` (default) or `live_video` (H4).
    public var pairRole: String?
    /// The primary still's hash, for `live_video`.
    public var pairSha256: String?
    /// iOS "also keep unedited originals" (H3).
    public var stackKey: String?
    /// Upload despite a tombstone ("back up again").
    public var overrideTombstone: Bool

    public init(sha256: String, filename: String, mime: String, localId: String? = nil,
                createdAt: String? = nil, modifiedAt: String? = nil, pairRole: String? = nil,
                pairSha256: String? = nil, stackKey: String? = nil, overrideTombstone: Bool = false) {
        self.sha256 = sha256
        self.filename = filename
        self.mime = mime
        self.localId = localId
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.pairRole = pairRole
        self.pairSha256 = pairSha256
        self.stackKey = stackKey
        self.overrideTombstone = overrideTombstone
    }
}

/// Pure tus 1.0.0 request builders (P§7.3, P§11.5). The iOS engine sends these through a
/// background URLSession with file bodies (`uploadTask(with:fromFile:)`), so they carry headers
/// only. `authorize` adds the bearer token and client header every engine request needs.
public enum TusRequests {
    public static let tusVersion = "1.0.0"
    public static let uploadsPath = "/api/v1/uploads"
    public static let offsetContentType = "application/offset+octet-stream"

    /// `POST /api/v1/uploads`: creation, or creation-with-upload when `bodyFile` is set (single
    /// shot ≤ 64 MiB on iOS; the body is the file, attached by the upload task).
    public static func create(base: URL, meta: UploadMeta, length: Int64, bodyFile: URL?) -> URLRequest {
        var r = URLRequest(url: Endpoints.join(base, uploadsPath))
        r.httpMethod = "POST"
        r.setValue(tusVersion, forHTTPHeaderField: "Tus-Resumable")
        r.setValue(String(length), forHTTPHeaderField: "Upload-Length")
        r.setValue(encodeMetadata(meta), forHTTPHeaderField: "Upload-Metadata")
        if bodyFile != nil {
            r.setValue(offsetContentType, forHTTPHeaderField: "Content-Type")
        }
        return r
    }

    /// `HEAD <session>`: the server's offset (R2 ambiguity, `offset_mismatch`).
    public static func head(_ url: URL) -> URLRequest {
        var r = URLRequest(url: url)
        r.httpMethod = "HEAD"
        r.setValue(tusVersion, forHTTPHeaderField: "Tus-Resumable")
        return r
    }

    /// `PATCH <session>` at `offset`; the body is the chunk file.
    public static func patch(_ url: URL, offset: Int64) -> URLRequest {
        var r = URLRequest(url: url)
        r.httpMethod = "PATCH"
        r.setValue(tusVersion, forHTTPHeaderField: "Tus-Resumable")
        r.setValue(String(offset), forHTTPHeaderField: "Upload-Offset")
        r.setValue(offsetContentType, forHTTPHeaderField: "Content-Type")
        return r
    }

    /// `DELETE <session>` (termination).
    public static func terminate(_ url: URL) -> URLRequest {
        var r = URLRequest(url: url)
        r.httpMethod = "DELETE"
        r.setValue(tusVersion, forHTTPHeaderField: "Tus-Resumable")
        return r
    }

    /// Adds `Authorization` and `PicTunnel-Client` for requests that do not go through `ServerClient`.
    public static func authorize(_ request: URLRequest, accessToken: String, clientHeader: String) -> URLRequest {
        var r = request
        r.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        r.setValue(clientHeader, forHTTPHeaderField: EngineHTTP.clientHeaderName)
        return r
    }

    /// tus `Upload-Metadata`: `key base64(value)` pairs (standard, padded base64), comma-separated,
    /// in the order of P§7.3.
    public static func encodeMetadata(_ m: UploadMeta) -> String {
        var pairs: [(String, String)] = [("sha256", m.sha256), ("filename", m.filename), ("mime", m.mime)]
        if let v = m.localId { pairs.append(("local_id", v)) }
        if let v = m.createdAt { pairs.append(("created_at", v)) }
        if let v = m.modifiedAt { pairs.append(("modified_at", v)) }
        if let v = m.pairRole { pairs.append(("pair_role", v)) }
        if let v = m.pairSha256 { pairs.append(("pair_sha256", v)) }
        if let v = m.stackKey { pairs.append(("stack_key", v)) }
        if m.overrideTombstone { pairs.append(("override_tombstone", "1")) }
        return pairs.map { "\($0.0) \(Data($0.1.utf8).base64EncodedString())" }.joined(separator: ",")
    }
}

/// A `201` creation answer. `assetId` is set when it finalized (single shot) or the content was
/// already on the server; `url` is the `Location` resolved against the endpoint it came from.
public struct TusCreated: Equatable, Sendable {
    public var url: URL
    public var offset: Int64
    public var expires: String?
    public var assetId: String?
    public var assetCreated: Bool?

    public init?(_ raw: ServerOutcome, base: URL) {
        guard raw.isSuccess, let location = raw.header("Location"),
              let url = URL(string: location, relativeTo: base)?.absoluteURL else { return nil }
        self.url = url
        offset = raw.uploadOffset ?? 0
        expires = raw.header("Upload-Expires")
        assetId = raw.header("PicTunnel-Asset-Id").flatMap { $0.isEmpty ? nil : $0 }
        assetCreated = raw.header("PicTunnel-Asset-Created").map { $0.lowercased() == "true" }
    }
}

/// A `HEAD` answer.
public struct TusHead: Equatable, Sendable {
    public var offset: Int64
    public var length: Int64?
    public var expires: String?
    public var assetId: String?

    public init(offset: Int64, length: Int64?, expires: String?, assetId: String?) {
        self.offset = offset
        self.length = length
        self.expires = expires
        self.assetId = assetId
    }

    public init?(_ raw: ServerOutcome) {
        guard raw.isSuccess, let offset = raw.uploadOffset else { return nil }
        self.init(offset: offset, length: raw.header("Upload-Length").flatMap { Int64($0) },
                  expires: raw.header("Upload-Expires"),
                  assetId: raw.header("PicTunnel-Asset-Id").flatMap { $0.isEmpty ? nil : $0 })
    }
}

/// A `PATCH` answer; the one that completes the upload carries the asset id.
public struct TusPatched: Equatable, Sendable {
    public var offset: Int64
    public var assetId: String?
    public var assetCreated: Bool?

    public init(offset: Int64, assetId: String?, assetCreated: Bool?) {
        self.offset = offset
        self.assetId = assetId
        self.assetCreated = assetCreated
    }

    public init?(_ raw: ServerOutcome) {
        guard raw.isSuccess, let offset = raw.uploadOffset else { return nil }
        self.init(offset: offset, assetId: raw.header("PicTunnel-Asset-Id").flatMap { $0.isEmpty ? nil : $0 },
                  assetCreated: raw.header("PicTunnel-Asset-Created").map { $0.lowercased() == "true" })
    }
}
