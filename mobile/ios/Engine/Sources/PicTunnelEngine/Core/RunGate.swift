import Foundation

/// Tracks every pipeline run of the process (BGAppRefresh, BGProcessing, the iOS 26 continued
/// "Back up now", foreground runs, network-change and follow-up runs) so that pairing and
/// unpairing can stop them and wait until they have ended (the Kotlin `RunCoordinator.preempt`).
///
/// A run starts its body as a task of its own, so `preempt` can cancel it; the caller's own
/// cancellation (a BGTask expiring) is forwarded to it as well.
public final class RunGate: @unchecked Sendable {
    private struct Job: Sendable {
        let cancel: @Sendable () -> Void
        let wait: @Sendable () async -> Void
    }

    private let lock = NSLock()
    private var jobs: [UInt64: Job] = [:]
    private var preempted = Set<UInt64>()
    private var nextId: UInt64 = 0
    private var preempting = 0

    public init() {}

    /// Runs in progress.
    public var running: Int { locked { jobs.count } }

    /// Runs `body` as a tracked run. Nil when a preemption is in progress (nothing starts then),
    /// when the run was preempted, or when `body` returned nil.
    public func run<T: Sendable>(_ body: @escaping @Sendable () async -> T?) async -> T? {
        let started: (UInt64, Task<T?, Never>)? = locked {
            guard preempting == 0 else { return nil }
            nextId += 1
            let id = nextId
            let task = Task { await body() }
            jobs[id] = Job(cancel: { task.cancel() }, wait: { _ = await task.value })
            return (id, task)
        }
        guard let (id, task) = started else { return nil }
        let out = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        let wasPreempted: Bool = locked {
            jobs[id] = nil
            return preempted.remove(id) != nil
        }
        return wasPreempted ? nil : out
    }

    /// Cancels every run in progress, waits until all have ended, then runs `block` with no run
    /// starting meanwhile.
    public func preempt<T>(_ block: () async throws -> T) async rethrows -> T {
        let current: [Job] = locked {
            preempting += 1
            preempted.formUnion(jobs.keys)
            return Array(jobs.values)
        }
        defer { locked { preempting -= 1 } }
        for job in current { job.cancel() }
        for job in current { await job.wait() }
        return try await block()
    }

    private func locked<R>(_ body: () -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
