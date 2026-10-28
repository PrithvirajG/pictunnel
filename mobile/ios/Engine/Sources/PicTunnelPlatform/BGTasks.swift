#if os(iOS)
import BackgroundTasks
import Foundation
import PicTunnelEngine

/// Background runs through BGTaskScheduler (M§4.6):
/// - `io.github.prithvirajg.pictunnel.refresh` (`BGAppRefreshTask`): a short run, mostly scan and
///   check, about every 15 minutes at the system's discretion.
/// - `io.github.prithvirajg.pictunnel.process` (`BGProcessingTask`): a long run for hashing and
///   uploading, with external power required when "charging only" is on.
/// - On iOS 26, a user-started "Back up now" runs as a `BGContinuedProcessingTask`
///   (`io.github.prithvirajg.pictunnel.continued.<id>`), which the system keeps alive with a
///   progress UI while the app is in the background.
///
/// Uploads themselves continue in the background `URLSession` regardless; these tasks only give
/// the pipeline time to scan, hash, check and enqueue.
public final class BGTasks: @unchecked Sendable {
    public static let refreshId = "io.github.prithvirajg.pictunnel.refresh"
    public static let processingId = "io.github.prithvirajg.pictunnel.process"
    public static let continuedPrefix = "io.github.prithvirajg.pictunnel.continued"
    /// Refresh tasks get about 30 s; leave room to finish.
    public static let refreshBudgetMs: Int64 = 25_000
    public static let refreshInterval: TimeInterval = 15 * 60

    private let runtime: EngineRuntime
    private let settings: () -> EngineSettings

    public init(runtime: EngineRuntime, settings: @escaping () -> EngineSettings) {
        self.runtime = runtime
        self.settings = settings
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
            self.run(task, budget: RunBudget(maxDurationMs: Self.refreshBudgetMs))
        }
        _ = scheduler.register(forTaskWithIdentifier: Self.processingId, using: nil) { [weak self] task in
            guard let self, let task = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            self.run(task, budget: RunBudget())
        }
    }

    private func run(_ task: BGTask, budget: RunBudget) {
        let runtime = self.runtime
        let work = Task {
            let report = await runtime.runOnce(budget: budget)
            task.setTaskCompleted(success: report.map { $0.stop != .needsRepair && $0.stop != .serverUntrusted } ?? true)
        }
        // The run detaches from uploads in flight and returns promptly when cancelled.
        task.expirationHandler = { work.cancel() }
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

    #if compiler(>=6.2)
    /// "Back up now" on iOS 26: a continued processing task with the system's progress UI. False
    /// when it could not be submitted (the caller then runs in the foreground).
    @available(iOS 26.0, *)
    public func startContinued(title: String, subtitle: String) -> Bool {
        let id = "\(Self.continuedPrefix).\(UUID().uuidString)"
        let runtime = self.runtime
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: id, using: nil) { task in
            guard let task = task as? BGContinuedProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            let progress = task.progress
            progress.totalUnitCount = 0
            let ticker = Task {
                // The system expires a continued task that reports no progress.
                while !Task.isCancelled {
                    if let s = await runtime.controller()?.status() {
                        progress.totalUnitCount = Int64(max(s.total, 1))
                        progress.completedUnitCount = Int64(min(s.backedUp, max(s.total, 1)))
                    }
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                }
            }
            let work = Task {
                let report = await runtime.runOnce(budget: RunBudget())
                ticker.cancel()
                progress.completedUnitCount = progress.totalUnitCount
                task.setTaskCompleted(success: report.map { $0.stop == .idle } ?? false)
            }
            task.expirationHandler = {
                ticker.cancel()
                work.cancel()
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
#endif
