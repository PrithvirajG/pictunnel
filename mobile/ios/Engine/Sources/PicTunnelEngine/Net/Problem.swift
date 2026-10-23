import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// An RFC 9457 `application/problem+json` body (P§3, P§8). Every field is optional so an odd or
/// partial body never fails parsing; `code` is the stable catalogue key `decide()` switches on.
public struct Problem: Equatable, Sendable {
    public var type: String?
    public var title: String?
    public var status: Int?
    public var detail: String?
    public var code: String?
    public var requestId: String?

    public init(type: String? = nil, title: String? = nil, status: Int? = nil, detail: String? = nil,
                code: String? = nil, requestId: String? = nil) {
        self.type = type
        self.title = title
        self.status = status
        self.detail = detail
        self.code = code
        self.requestId = requestId
    }

    /// Parses a problem out of a JSON body; nil unless the body is an object with a `code`, `type`
    /// or `title` (as lenient as the Kotlin engine).
    public init?(_ body: JSONValue?) {
        guard let body, case .object = body else { return nil }
        let code = body["code"]?.stringValue
        let type = body["type"]?.stringValue
        guard code != nil || type != nil || body["title"]?.stringValue != nil else { return nil }
        self.init(type: type, title: body["title"]?.stringValue, status: body["status"]?.intValue,
                  detail: body["detail"]?.stringValue,
                  code: code ?? type.flatMap { $0.hasPrefix(Self.typePrefix) ? String($0.dropFirst(Self.typePrefix.count)) : nil },
                  requestId: body["request_id"]?.stringValue)
    }

    static let typePrefix = "urn:pictunnel:problem:"
}

/// The result of an engine call: a value with the raw outcome it came from, or a failure whose raw
/// outcome (`status`/`headers`/`body`, or `transport`) goes straight into `Decide.decide`.
/// `failure` marks failures the engine must surface beyond what `decide()` does.
public enum Outcome<T: Sendable>: Sendable {
    case ok(T, raw: ServerOutcome)
    case fail(ServerOutcome, NetFailure? = nil)

    public var raw: ServerOutcome {
        switch self {
        case let .ok(_, raw): raw
        case let .fail(raw, _): raw
        }
    }

    public var value: T? {
        if case let .ok(v, _) = self { return v }
        return nil
    }
}

/// Failures that need more than the problem catalogue.
public enum NetFailure: Error, Equatable, Sendable {
    /// The credentials are gone (reused or revoked refresh token): pair again (M§4.4).
    case needsRepair
    /// No endpoint answered, and at least one refused TLS: the certificate is neither trusted by the
    /// system for the host nor matching the stored pin (P§6.3). Shown as "server identity changed".
    case tlsRejected(host: String)
    /// The request targets a host that is not one of the paired endpoints; it was not sent, so the
    /// bearer token never leaves the paired server.
    case foreignHost(String)
    /// The token refresh failed transiently (network or server error); the tokens are kept. The
    /// server may have rotated the refresh token already, so the caller retries the refresh inside
    /// the server's 30 s grace window (P§6.2) rather than after a generic backoff.
    case refreshFailed
}

/// A non-2xx answer from a call that has no `Outcome` (server info).
public struct ServerError: Error, Sendable {
    public let raw: ServerOutcome
    public init(_ raw: ServerOutcome) { self.raw = raw }
}

extension ServerOutcome {
    /// The outcome of an HTTP exchange. The body is kept only when it parses as JSON; an HTML error
    /// page from a proxy becomes `nil` and `decide()` falls back to the status (R7).
    public init(response: HTTPURLResponse, data: Data) {
        var headers: [String: String] = [:]
        for (k, v) in response.allHeaderFields {
            if let k = k as? String { headers[k] = (v as? String) ?? "\(v)" }
        }
        let body = data.isEmpty ? nil : try? JSONDecoder().decode(JSONValue.self, from: data)
        self.init(status: response.statusCode, headers: headers, body: body)
    }

    /// The outcome of a request that got no response.
    public init(error: Error) {
        self.init(transport: Transport.classify(error))
    }

    public var isSuccess: Bool { status.map { (200...299).contains($0) } ?? false }

    public var problem: Problem? { Problem(body) }

    /// `Upload-Offset` (tus HEAD/PATCH, and `409 offset_mismatch`).
    public var uploadOffset: Int64? { header("Upload-Offset").flatMap { Int64($0.trimmingCharacters(in: .whitespaces)) } }

    /// `Retry-After` as seconds from `now`: delta-seconds or an HTTP-date (P§3; 429 and 503).
    /// A date in the past gives 0; a missing or malformed value gives nil.
    public func retryAfter(now: Date) -> TimeInterval? {
        guard let raw = header("Retry-After")?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        if raw.allSatisfy(\.isASCIIDigitChar) {
            return Int(raw).map(TimeInterval.init)
        }
        guard let date = HTTPDate.parse(raw) else { return nil }
        return max(0, date.timeIntervalSince(now).rounded())
    }
}

extension Character {
    fileprivate var isASCIIDigitChar: Bool { ("0"..."9").contains(self) }
}

/// IMF-fixdate (RFC 9110), the only HTTP-date form servers must send:
/// `Sun, 04 Oct 2026 12:00:00 GMT`. Parsed by hand: no locale, no shared formatter.
enum HTTPDate {
    private static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                                 "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    static func parse(_ s: String) -> Date? {
        let parts = s.split(separator: " ")
        guard parts.count == 6, parts[0].hasSuffix(","), parts[5] == "GMT",
              let day = Int(parts[1]), let monthIndex = months.firstIndex(of: String(parts[2])),
              let year = Int(parts[3]) else { return nil }
        let time = parts[4].split(separator: ":")
        guard time.count == 3, let h = Int(time[0]), let m = Int(time[1]), let sec = Int(time[2]),
              (0...23).contains(h), (0...59).contains(m), (0...60).contains(sec), (1...31).contains(day)
        else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = DateComponents(year: year, month: monthIndex + 1, day: day, hour: h, minute: m, second: sec)
        return cal.date(from: c)
    }
}

extension Transport {
    /// Classifies a failed request (P§10.5), like the Kotlin engine:
    /// - every endpoint failed before sending: `tls` if any refused TLS, else `offline` (never an
    ///   attempt, R5);
    /// - a handshake or pin failure on its own: `tls`;
    /// - a timeout: `timeout`; anything else after the request may have left: `reset`.
    public static func classify(_ error: Error) -> Transport {
        switch error {
        case let e as EndpointsError:
            switch e {
            case let .allFailed(_, tlsHost): return tlsHost != nil ? .tls : .offline
            case .noEndpoints: return .offline
            }
        case let f as TransportFailure:
            if f.isTLS { return .tls }
            if f.code == .timedOut { return .timeout }
            if f.sent != true, TransportFailure.preSendCodes.contains(f.code) { return .offline }
            return .reset
        case let u as URLError:
            return classify(TransportFailure(code: u.code))
        default:
            return .reset
        }
    }
}
