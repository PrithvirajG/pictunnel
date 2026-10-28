import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A download that got no usable answer.
public struct DownloadError: Error, Sendable {
    public let raw: ServerOutcome
    public init(_ raw: ServerOutcome) { self.raw = raw }

    /// The problem code, `http_<status>`, or the transport kind.
    public var code: String {
        if let c = raw.problem?.code { return c }
        if let s = raw.status { return "http_\(s)" }
        return raw.transport?.rawValue ?? "unknown"
    }
}

extension ServerClient {
    /// One ranged `GET` of a download.
    public static let downloadChunkBytes: Int64 = 8 << 20

    /// `GET /api/v1/assets/{id}/original` into `file` (created or truncated), in ranged requests of
    /// `chunkBytes`, so memory stays bounded and every request gets the engine's auth, refresh and
    /// endpoint fallback. `If-Range` with the first answer's `ETag` (the content hash) keeps the
    /// pieces from mixing two files: a server that answers `200` restarts the file. Returns the size.
    public func downloadOriginal(assetId: String, to file: URL, chunkBytes: Int64 = ServerClient.downloadChunkBytes) async throws -> Int64 {
        let fm = FileManager.default
        guard fm.createFile(atPath: file.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        let path = "/api/v1/assets/\(assetId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? assetId)/original"
        var offset: Int64 = 0
        var total: Int64?
        var etag: String?
        while total.map({ offset < $0 }) ?? true {
            try Task.checkCancellation()
            let from = offset
            let validator = etag
            let out = await authorized(path: path) { url in
                var r = URLRequest(url: url)
                r.setValue("bytes=\(from)-\(from + chunkBytes - 1)", forHTTPHeaderField: "Range")
                if let validator { r.setValue(validator, forHTTPHeaderField: "If-Range") }
                return r
            }
            let raw = out.raw
            switch (out, raw.status) {
            case let (.ok(data, _), 200?):
                // The whole file (no range support, or it changed since the first piece).
                try handle.truncate(atOffset: 0)
                try handle.write(contentsOf: data)
                return Int64(data.count)
            case let (.ok(data, _), 206?):
                guard let range = Self.contentRange(raw.header("Content-Range")), range.start == offset, !data.isEmpty else {
                    throw DownloadError(raw)
                }
                if etag == nil { etag = raw.header("ETag") }
                total = range.total
                try handle.write(contentsOf: data)
                offset += Int64(data.count)
            case (.fail, 416?) where offset == 0:
                return 0 // an empty file has no satisfiable range
            default:
                throw DownloadError(raw)
            }
        }
        return offset
    }

    /// `bytes <start>-<end>/<total>`.
    static func contentRange(_ value: String?) -> (start: Int64, total: Int64?)? {
        guard let v = value?.trimmingCharacters(in: .whitespaces), v.lowercased().hasPrefix("bytes ") else { return nil }
        let spec = v.dropFirst(6)
        let parts = spec.split(separator: "/", maxSplits: 1)
        guard parts.count == 2, let dash = parts[0].firstIndex(of: "-"), let start = Int64(parts[0][..<dash]) else { return nil }
        return (start, Int64(parts[1]))
    }

    /// `POST /api/v1/auth/logout`: best effort when unpairing (M§3).
    public func logout() async -> ServerOutcome {
        await authorized(path: "/api/v1/auth/logout") { url in
            var r = URLRequest(url: url)
            r.httpMethod = "POST"
            return r
        }.raw
    }
}
