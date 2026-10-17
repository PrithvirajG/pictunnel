import Foundation

/// A parsed QR pairing payload (P§6.3). `endpoints` keep preference order, deduplicated.
public struct PairInfo: Equatable, Sendable {
    public var serverId: String
    public var code: String
    public var fingerprint: String
    public var endpoints: [String]
}

/// Pairing URI errors; raw values are the P§10.3 error names.
public enum PairURIError: String, Error, Sendable {
    case invalidScheme = "invalid_scheme"
    case unsupportedVersion = "unsupported_version"
    case missingServerId = "missing_server_id"
    case invalidCode = "invalid_code"
    case missingFingerprint = "missing_fingerprint"
    case missingEndpoint = "missing_endpoint"
    case insecureEndpoint = "insecure_endpoint"
}

/// Parses `pictunnel://pair?...` URIs and applies the pinning rule (P§6.3, P§10.3).
public enum PairURI {
    /// Crockford base32 without I, L, O, U, shown as `XXXX-XXXX-XX`.
    private static let codeAlphabet = Set("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    /// Errors are checked in the order P§10.3 lists them.
    public static func parse(_ uri: String) -> Result<PairInfo, PairURIError> {
        guard let sep = uri.range(of: "://") else { return .failure(.invalidScheme) }
        let scheme = uri[..<sep.lowerBound]
        var rest = uri[sep.upperBound...]
        if let hash = rest.firstIndex(of: "#") { rest = rest[..<hash] }
        let q = rest.firstIndex(of: "?")
        let authorityAndPath = q.map { rest[..<$0] } ?? rest
        let rawQuery = q.map { rest[rest.index(after: $0)...] } ?? ""
        let host = authorityAndPath.prefix { $0 != "/" }
        let path = authorityAndPath.dropFirst(host.count)
        guard scheme.lowercased() == "pictunnel", host.lowercased() == "pair", path.isEmpty || path == "/" else {
            return .failure(.invalidScheme)
        }

        let params = query(rawQuery)
        func first(_ key: String) -> String? { params.first { $0.0 == key }?.1 }

        guard first("v") == "1" else { return .failure(.unsupportedVersion) }
        guard let sid = first("sid"), !sid.isEmpty else { return .failure(.missingServerId) }
        guard let code = first("code"), isValidCode(code) else { return .failure(.invalidCode) }
        guard let fp = first("fp"), !fp.isEmpty else { return .failure(.missingFingerprint) }
        var endpoints: [String] = []
        for (k, v) in params where k == "u" && !v.isEmpty && !endpoints.contains(v) {
            endpoints.append(v)
        }
        guard !endpoints.isEmpty else { return .failure(.missingEndpoint) }
        guard endpoints.allSatisfy({ $0.lowercased().hasPrefix("https://") }) else {
            return .failure(.insecureEndpoint)
        }
        return .success(PairInfo(serverId: sid, code: code, fingerprint: fp, endpoints: endpoints))
    }

    /// Pinning rule: a chain the system trusts (and that matches the host) is accepted; otherwise
    /// the leaf SPKI SHA-256 must equal `pin`. Both are unpadded base64url; padding is ignored and
    /// the compare is constant-time.
    public static func acceptConnection(systemTrusted: Bool, spkiSha256: String, pin: String) -> Bool {
        if systemTrusted { return true }
        let a = Array(trimPadding(spkiSha256).utf8)
        let b = Array(trimPadding(pin).utf8)
        guard !a.isEmpty, a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count { diff |= a[i] ^ b[i] }
        return diff == 0
    }

    /// `^[0-9A-HJKMNP-TV-Z]{4}-[0-9A-HJKMNP-TV-Z]{4}-[0-9A-HJKMNP-TV-Z]{2}$`
    private static func isValidCode(_ code: String) -> Bool {
        let groups = code.split(separator: "-", omittingEmptySubsequences: false)
        guard groups.map(\.count) == [4, 4, 2] else { return false }
        return groups.allSatisfy { $0.allSatisfy(codeAlphabet.contains) }
    }

    private static func trimPadding(_ s: String) -> Substring {
        var t = Substring(s)
        while t.last == "=" { t = t.dropLast() }
        return t
    }

    private static func query(_ raw: Substring) -> [(String, String)] {
        raw.split(separator: "&").map { pair in
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            return (decode(parts[0]), parts.count > 1 ? decode(parts[1]) : "")
        }
    }

    /// Form decoding, as `URLDecoder` does on Android: `+` is a space, then percent escapes.
    private static func decode(_ s: Substring) -> String {
        let plus = s.replacingOccurrences(of: "+", with: " ")
        return plus.removingPercentEncoding ?? plus
    }
}
