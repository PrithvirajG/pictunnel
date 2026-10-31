#if os(iOS)
import Foundation
import PicTunnelEngine

/// `BackgroundUploader` over the background `URLSession` `io.github.prithvirajg.pictunnel.upload`
/// (M§6). Tasks keep running while the app is suspended or after it was terminated; the system
/// relaunches the app for their completions (`sessionSendsLaunchEvents`), and AppDelegate forwards
/// `application(_:handleEventsForBackgroundURLSession:completionHandler:)` to `handleEvents`.
///
/// - Every task body is a file (`uploadTask(with:fromFile:)`); the bodyless tus creation sends an
///   empty file, because background sessions only run upload and download tasks.
/// - Each task's response body is collected (`didReceive data`), so problem codes reach `decide()`.
/// - TLS goes through the same `PinningDelegate` as the engine's foreground calls. A certificate
///   it refuses is reported as `TransportFailure(pinRejectedHost:)`: backup pauses as "server
///   certificate changed" instead of burning attempts. Task metrics tell sent from unsent failures.
/// - Completions that arrive before the engine installed its handler (a relaunch before pairing
///   data is loaded) are kept and delivered once it does.
///
/// Create exactly one instance per process, early in `didFinishLaunching`.
public final class BackgroundSessionUploader: NSObject, BackgroundUploader, URLSessionDataDelegate, @unchecked Sendable {
    public static let identifier = "io.github.prithvirajg.pictunnel.upload"

    private let pinning: PinningDelegate
    private let clientHeader: String
    private let scratchDir: URL
    private let lock = NSLock()
    private var handler: ((UploadCompletion) async -> Void)?
    private var buffered: [UploadCompletion] = []
    private var bodies: [Int: Data] = [:]
    private var sent: [Int: Bool] = [:]
    private var systemCompletion: (() -> Void)?
    private let delivering = DispatchGroup()
    private var _cellularAllowed: () -> Bool = { true }
    private var session: URLSession!

    /// `scratchDir` holds the empty body file of bodyless requests.
    public init(pinning: PinningDelegate, clientHeader: String, scratchDir: URL) {
        self.pinning = pinning
        self.clientHeader = clientHeader
        self.scratchDir = scratchDir
        super.init()
        let config = URLSessionConfiguration.background(withIdentifier: Self.identifier)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        config.httpMaximumConnectionsPerHost = EngineSettings.maxConcurrency
        config.httpAdditionalHeaders = [EngineHTTP.clientHeaderName: clientHeader]
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    /// Read when a task is created: false keeps it off cellular ("Wi-Fi only").
    public var cellularAllowed: () -> Bool {
        get { lock.lock(); defer { lock.unlock() }; return _cellularAllowed }
        set { lock.lock(); _cellularAllowed = newValue; lock.unlock() }
    }

    // MARK: - BackgroundUploader

    public func setCompletionHandler(_ handler: @escaping @Sendable (UploadCompletion) async -> Void) {
        lock.lock()
        self.handler = handler
        let pending = buffered
        buffered = []
        lock.unlock()
        for c in pending { deliver(c, to: handler) }
    }

    public func enqueue(request: URLRequest, file: URL?, taskDescription: String) async throws {
        var req = request
        req.setValue(clientHeader, forHTTPHeaderField: EngineHTTP.clientHeaderName)
        req.allowsCellularAccess = cellularAllowed()
        let body = try file ?? emptyBody()
        let task = session.uploadTask(with: req, fromFile: body)
        task.taskDescription = taskDescription
        task.resume()
    }

    public func pendingTaskDescriptions() async -> [String] {
        let tasks = await session.allTasks
        return tasks.filter { $0.state == .running || $0.state == .suspended }.compactMap(\.taskDescription)
    }

    // MARK: - app hooks

    /// AppDelegate's `handleEventsForBackgroundURLSession`: the system's completion handler is
    /// called once every delivered completion has been applied.
    public func handleEvents(completionHandler: @escaping () -> Void) {
        lock.lock()
        systemCompletion = completionHandler
        lock.unlock()
    }

    /// Cancels every task (unpairing). Their completions still arrive, as cancellations.
    public func cancelAll() {
        session.getAllTasks { tasks in tasks.forEach { $0.cancel() } }
    }

    // MARK: - URLSession delegate

    public func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                           completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        pinning.urlSession(session, task: task, didReceive: challenge, completionHandler: completionHandler)
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        bodies[dataTask.taskIdentifier, default: Data()].append(data)
        lock.unlock()
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        let transactions = metrics.transactionMetrics
        guard !transactions.isEmpty else { return }
        lock.lock()
        sent[task.taskIdentifier] = transactions.contains { $0.requestStartDate != nil }
        lock.unlock()
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let id = task.taskIdentifier
        lock.lock()
        let body = bodies.removeValue(forKey: id)
        let wasSent = sent.removeValue(forKey: id)
        lock.unlock()
        guard let desc = task.taskDescription else { return }
        let http = task.response as? HTTPURLResponse
        var failure: Error?
        if let handshake = pinning.takeFailure(session: session, taskIdentifier: id) {
            failure = TransportFailure(handshake: handshake, error: error ?? URLError(.cancelled), sent: false)
        } else if let error {
            failure = TransportFailure(code: (error as? URLError)?.code ?? .unknown, sent: wasSent)
        } else if http == nil {
            failure = TransportFailure(code: .badServerResponse, sent: true)
        }
        var headers: [String: String] = [:]
        for (k, v) in http?.allHeaderFields ?? [:] {
            if let k = k as? String { headers[k] = (v as? String) ?? "\(v)" }
        }
        let completion = UploadCompletion(taskDescription: desc, status: failure == nil ? http?.statusCode : nil,
                                          headers: headers, body: body, error: failure)
        lock.lock()
        guard let handler else {
            buffered.append(completion)
            lock.unlock()
            return
        }
        lock.unlock()
        deliver(completion, to: handler)
    }

    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        lock.lock()
        let done = systemCompletion
        systemCompletion = nil
        lock.unlock()
        guard let done else { return }
        delivering.notify(queue: .main) { done() }
    }

    // MARK: - helpers

    private func deliver(_ c: UploadCompletion, to handler: @escaping (UploadCompletion) async -> Void) {
        delivering.enter()
        Task {
            await handler(c)
            self.delivering.leave()
        }
    }

    private func emptyBody() throws -> URL {
        let url = scratchDir.appendingPathComponent("empty.body")
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try fm.createDirectory(at: scratchDir, withIntermediateDirectories: true)
            guard fm.createFile(atPath: url.path, contents: Data()) else { throw CocoaError(.fileWriteUnknown) }
        }
        return url
    }
}
#endif
