import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A `BackgroundUploader` over ordinary URLSession tasks: `uploadTask(with:fromFile:)` for a body,
/// a data task otherwise. Used on Linux and in tests, and anywhere tasks need not outlive the
/// process. Its tasks end with the process, so after a relaunch nothing is pending. The session
/// should be built with `EngineHTTP.makeSession` so pinning applies (P§6.3).
public final class ForegroundUploader: BackgroundUploader, @unchecked Sendable {
    private let session: URLSession
    private let lock = NSLock()
    private var handler: (@Sendable (UploadCompletion) async -> Void)?
    private var pending: Set<String> = []

    public init(session: URLSession) {
        self.session = session
    }

    public func setCompletionHandler(_ handler: @escaping @Sendable (UploadCompletion) async -> Void) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    public func enqueue(request: URLRequest, file: URL?, taskDescription: String) async throws {
        let done: @Sendable (Data?, URLResponse?, Error?) -> Void = { [weak self] data, response, error in
            guard let self else { return }
            self.lock.lock()
            self.pending.remove(taskDescription)
            let handler = self.handler
            self.lock.unlock()
            let http = response as? HTTPURLResponse
            var headers: [String: String] = [:]
            for (k, v) in http?.allHeaderFields ?? [:] {
                if let k = k as? String { headers[k] = (v as? String) ?? "\(v)" }
            }
            let completion = UploadCompletion(taskDescription: taskDescription, status: error == nil ? http?.statusCode : nil,
                                              headers: headers, body: data, error: error ?? (http == nil ? URLError(.badServerResponse) : nil))
            Task { await handler?(completion) }
        }
        let task: URLSessionTask
        if let file {
            task = session.uploadTask(with: request, fromFile: file, completionHandler: done)
        } else {
            task = session.dataTask(with: request, completionHandler: done)
        }
        task.taskDescription = taskDescription
        track(taskDescription)
        task.resume()
    }

    public func pendingTaskDescriptions() async -> [String] { snapshot() }

    private func track(_ d: String) {
        lock.lock()
        pending.insert(d)
        lock.unlock()
    }

    private func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return Array(pending)
    }
}
