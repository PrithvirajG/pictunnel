import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A request that produced no HTTP response, with what is known about whether it left the device.
public struct TransportFailure: Error, Sendable {
    public let code: URLError.Code
    /// From the task's metrics: true once a request started on a connection, false when none did,
    /// nil when no metrics arrived (Linux, URLProtocol stubs). See `Endpoints` for the fallback rule.
    public let sent: Bool?
    /// The pinning delegate refused this task's certificate (P§6.3). Nothing was sent.
    public let pinRejectedHost: String?
    /// The caller's task was cancelled; the request must not be replayed.
    public let cancelled: Bool

    public init(code: URLError.Code, sent: Bool? = nil, pinRejectedHost: String? = nil, cancelled: Bool = false) {
        self.code = code
        self.sent = sent
        self.pinRejectedHost = pinRejectedHost
        self.cancelled = cancelled
    }

    /// True when the request provably never reached the server: a pin rejection, metrics showing
    /// no request start, or (without metrics) an error that can only happen before sending.
    public var provablyUnsent: Bool {
        if cancelled { return false }
        if pinRejectedHost != nil { return true }
        if let sent { return !sent }
        return Self.preSendCodes.contains(code) || Self.handshakeCodes.contains(code)
    }

    /// The TLS handshake failed (no request was sent on that connection).
    public var isTLS: Bool {
        pinRejectedHost != nil || (Self.handshakeCodes.contains(code) && sent != true)
    }

    static let preSendCodes: Set<URLError.Code> = [
        .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
        .internationalRoamingOff, .dataNotAllowed, .callIsActive, .appTransportSecurityRequiresSecureConnection,
    ]
    static let handshakeCodes: Set<URLError.Code> = [
        .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
        .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .clientCertificateRejected,
        .clientCertificateRequired,
    ]
}

/// The engine's HTTP transport: a URLSession plus the `PicTunnel-Client` header that every engine
/// request carries (P§3 version gate, M§4.2).
public struct EngineHTTP: @unchecked Sendable {
    public static let clientHeaderName = "PicTunnel-Client"

    public let session: URLSession
    /// `ios/<app version>`.
    public let clientHeader: String
    /// Read URLSessionTaskMetrics to tell sent from unsent requests. Tests over `URLProtocol`
    /// stubs turn it off, because stubbed tasks carry no real connection metrics.
    public let useTaskMetrics: Bool

    public init(session: URLSession, clientHeader: String, useTaskMetrics: Bool = true) {
        self.session = session
        self.clientHeader = clientHeader
        self.useTaskMetrics = useTaskMetrics
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

    /// Sends one request. Cancelling the calling task cancels the URLSession task. Throws a
    /// `TransportFailure` when there is no HTTP response.
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var req = request
        req.setValue(clientHeader, forHTTPHeaderField: Self.clientHeaderName)
        let session = self.session
        let pinning = session.delegate as? PinningDelegate
        let observer = MetricsObserver()
        let box = TaskBox()
        let useMetrics = useTaskMetrics

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(Data, HTTPURLResponse), Error>) in
                let task = session.dataTask(with: req) { data, response, error in
                    if let error {
                        let id = box.taskIdentifier
                        let pinHost = id.flatMap { pinning?.takeRejection(taskIdentifier: $0) }
                        let code = (error as? URLError)?.code ?? .unknown
                        cont.resume(throwing: TransportFailure(
                            code: code,
                            sent: pinHost != nil ? false : (useMetrics ? observer.sent : nil),
                            pinRejectedHost: pinHost,
                            cancelled: box.isCancelled
                        ))
                    } else if let http = response as? HTTPURLResponse {
                        cont.resume(returning: (data ?? Data(), http))
                    } else {
                        cont.resume(throwing: TransportFailure(code: .badServerResponse, sent: true))
                    }
                }
                #if canImport(Darwin)
                if useMetrics { task.delegate = observer }
                #endif
                box.start(task)
            }
        } onCancel: {
            box.cancel()
        }
    }
}

/// Holds the task so cancellation can reach it, even when cancellation comes first.
private final class TaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var _cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _cancelled
    }

    var taskIdentifier: Int? {
        lock.lock()
        defer { lock.unlock() }
        return task?.taskIdentifier
    }

    func start(_ t: URLSessionTask) {
        lock.lock()
        task = t
        let cancelled = _cancelled
        lock.unlock()
        t.resume()
        if cancelled { t.cancel() }
    }

    func cancel() {
        lock.lock()
        _cancelled = true
        let t = task
        lock.unlock()
        t?.cancel()
    }
}

/// Per-task delegate collecting URLSessionTaskMetrics (Apple platforms). Metrics are delivered
/// before the task completes; when they are missing, `sent` stays nil.
final class MetricsObserver: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var _sent: Bool?

    var sent: Bool? {
        lock.lock()
        defer { lock.unlock() }
        return _sent
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        let transactions = metrics.transactionMetrics
        guard !transactions.isEmpty else { return }
        // A request that never started on a connection (no connect end, no request start) was not sent.
        let sent = transactions.contains { $0.requestStartDate != nil }
        lock.lock()
        _sent = sent
        lock.unlock()
    }
}
