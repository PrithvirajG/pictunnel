#if os(iOS)
import BackgroundTasks
import Foundation
import PicTunnelEngine

/// Background runs through BGTaskScheduler (M§4.6):
/// - `io.github.prithvirajg.pictunnel.refresh` (`BGAppRefreshTask`): a short run (25 s budget that
///   covers the scan too) for incremental scans, checks and enqueueing. It never starts a full
///   library scan (no change token yet, an expired one, limited access): that is left to the
///   processing task or a foreground run, so a refresh is not killed half way through one every time.
/// - `io.github.prithvirajg.pictunnel.process` (`BGProcessingTask`): a long run for hashing and
///   uploading, with external power required when "charging only" is on.
/// - On iOS 26, a user-started "Back up now" runs as a `BGContinuedProcessingTask`
///   (`io.github.prithvirajg.pictunnel.continued.<id>`), which the system keeps alive with a
///   progress UI while the app is in the background.
///
/// Every run goes through `EngineRuntime.runOnce`, so unpairing and pairing stop and await them.
/// On expiry the run is cancelled and the task is completed at once (not when the run has wound
/// down). Uploads themselves continue in the background `URLSession` regardless; these tasks only
/// give the pipeline time to scan, hash, check and enqueue.
public final class BGTasks: @unchecked Sendable {
    public static let refreshId = "io.github.prithvirajg.pictunnel.refresh"
    public static let processingId = "io.github.prithvirajg.pictunnel.process"
    public static let continuedPrefix = "io.github.prithvirajg.pictunnel.continued"
    /// Refresh tasks get about 30 s; leave room to finish.
    public static let refreshBudgetMs: Int64 = 25_000
    public static let refreshInterval: TimeInterval = 15 * 60

    private let runtime: () -> EngineRuntime?
    private let settings: () -> EngineSettings
    private let lock = NSLock()
    private var active: [UUID: Task<Void, Never>] = [:]
    private var _beforeRun: (@Sendable () async -> Void)?

    /// `runtime` is nil while the engine database could not be opened; runs are skipped then.
    public init(runtime: @escaping () -> EngineRuntime?, settings: @escaping () -> EngineSettings) {
        self.runtime = runtime
        self.settings = settings
    }

    /// Awaited before every background run (the app waits for the first network path report).
    public var beforeRun: (@Sendable () async -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _beforeRun }
        set { lock.lock(); _beforeRun = newValue; lock.unlock() }
    }

    /// Registers the launch handlers. Must run before `didFinishLaunching` returns.
    public func register() {
        let scheduler = BGTaskScheduler.shared
        _ = scheduler.register(forTaskWithIdentifier: Self.refreshId, using: nil) { [weak self] task in
            guard let self, let task = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            self.scheduleRefresh()
            self.run(task, budget: RunBudget(maxDurationMs: Self.refreshBudgetMs, allowFullScan: false)) { report in
                report.map { $0.stop != .needsRepair && $0.stop != .serverUntrusted } ?? true
            }
        }
        _ = scheduler.register(forTaskWithIdentifier: Self.processingId, using: nil) { [weak self] task in
            guard let self, let task = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            self.run(task, budget: RunBudget()) { report in
                report.map { $0.stop != .needsRepair && $0.stop != .serverUntrusted } ?? true
            }
        }
    }

    /// Runs one pipeline run for `task`. Its completion is reported once: when the run ends, or at
    /// once on expiry (the run is cancelled and winds down on its own).
    private func run(_ task: BGTask, budget: RunBudget, onExtra: (() -> Void)? = nil,
                     success: @escaping @Sendable (RunReport?) -> Bool) {
        let completion = TaskCompletion(task)
        let runtime = self.runtime()
        let beforeRun = self.beforeRun
        let id = UUID()
        let work = Task { [weak self] in
            await beforeRun?()
            let report = Task.isCancelled ? nil : await runtime?.runOnce(budget: budget)
            onExtra?()
            completion.complete(success(report))
            self?.forget(id)
        }
        track(id, work)
        task.expirationHandler = {
            work.cancel()
            onExtra?()
            completion.complete(false)
        }
    }

    public func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshId)
        request.earliestBeginDate = Date(timeIntervalSinceNow: Self.refreshInterval)
        try? BGTaskScheduler.shared.submit(request)
    }

    /// Asks for a processing run, not before `at` (nil: as soon as the system likes).
    public func scheduleProcessing(at: Date? = nil) {
        let request = BGProcessingTaskRequest(identifier: Self.processingId)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = settings().chargingOnly
        request.earliestBeginDate = at
        try? BGTaskScheduler.shared.submit(request)
    }

    /// After a run: keep the refresh going, and ask for a processing run while work is left.
    public func runFinished(_ report: RunReport) {
        scheduleRefresh()
        switch report.stop {
        case .needsRepair, .serverUntrusted, .paused:
            return
        default:
            break
        }
        if report.stop == .budget || report.nextAttemptAtMs != nil {
            scheduleProcessing(at: report.nextAttemptAtMs.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) })
        }
    }

    /// Unpairing: no more background runs. Pending requests are cancelled, and every task this
    /// object is running (refresh, processing, continued "Back up now") is cancelled; their runs
    /// are stopped and awaited by the runtime itself.
    public func cancelAll() {
        BGTaskScheduler.shared.cancelAllTaskRequests()
        lock.lock()
        let running = Array(active.values)
        active = [:]
        lock.unlock()
        running.forEach { $0.cancel() }
    }

    private func track(_ id: UUID, _ task: Task<Void, Never>) {
        lock.lock()
        active[id] = task
        lock.unlock()
    }

    private func forget(_ id: UUID) {
        lock.lock()
        active[id] = nil
        lock.unlock()
    }

    #if compiler(>=6.2)
    /// "Back up now" on iOS 26: a continued processing task with the system's progress UI. False
    /// when it could not be submitted (the caller then runs in the foreground).
    @available(iOS 26.0, *)
    public func startContinued(title: String, subtitle: String) -> Bool {
        let id = "\(Self.continuedPrefix).\(UUID().uuidString)"
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: id, using: nil) { [weak self] task in
            guard let self, let task = task as? BGContinuedProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            let progress = task.progress
            progress.totalUnitCount = 0
            let runtime = self.runtime()
            let ticker = Task {
                // The system expires a continued task that reports no progress.
                while !Task.isCancelled {
                    if let s = await runtime?.controller()?.status() {
                        progress.totalUnitCount = Int64(max(s.total, 1))
                        progress.completedUnitCount = Int64(min(s.backedUp, max(s.total, 1)))
                    }
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                }
            }
            self.run(task, budget: RunBudget(), onExtra: {
                ticker.cancel()
                progress.completedUnitCount = progress.totalUnitCount
            }) { report in
                report.map { $0.stop == .idle } ?? false
            }
        }
        guard registered else { return false }
        do {
            try BGTaskScheduler.shared.submit(BGContinuedProcessingTaskRequest(identifier: id, title: title, subtitle: subtitle))
            return true
        } catch {
            return false
        }
    }
    #endif
}

/// Calls `setTaskCompleted` once, whichever of the run's end and the expiry comes first.
private final class TaskCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var task: BGTask?

    init(_ task: BGTask) { self.task = task }

    func complete(_ success: Bool) {
        lock.lock()
        let t = task
        task = nil
        lock.unlock()
        t?.setTaskCompleted(success: success)
    }
}
#endif
