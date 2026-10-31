import Flutter
import Foundation
import Photos
import PicTunnelEngine
import PicTunnelPlatform
import UIKit

/// The Pigeon `EngineHostApi` (M§3) over the iOS engine, and the owner of the process-wide engine
/// pieces: the one background `URLSession`, the Keychain store, PhotoKit, BGTaskScheduler handlers
/// and the run conditions. `bootstrap()` runs in `didFinishLaunching` (also for background
/// launches), `attach(messenger:)` once Flutter's engine exists.
///
/// The engine database is opened in `bootstrap()`. When that fails (disk full, a protected file
/// before first unlock) there is no in-memory stand-in: calls that need the engine fail with
/// `internal`, and each one tries to open it again.
final class EngineHost: NSObject, EngineHostApi {
    static let shared = EngineHost()

    private let appVersion: String
    private let clientHeader: String
    private let store = KeychainCredentialStore()
    private let library = PhotoKitLibrary()
    private let relay = EventsRelay()
    private let notifier: PauseNotifier
    private let conditions = RunConditions()
    private let pinning: PinningDelegate
    private let dirs: Dirs
    private(set) var uploader: BackgroundSessionUploader!
    private var bgTasks: BGTasks!
    private var watcher: LibraryWatcher!
    /// Main thread only.
    private var followUp: DispatchWorkItem?

    private let engineLock = NSLock()
    private var db: EngineDB?
    private var runtime: EngineRuntime?

    private struct Dirs {
        let support: URL
        let staging: URL
        let scratch: URL
        let downloads: URL
    }

    private static let installedKey = "io.github.prithvirajg.pictunnel.installed"

    override init() {
        appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        clientHeader = EngineHTTP.clientHeader(version: appVersion)
        pinning = PinningDelegate(store: store)
        notifier = PauseNotifier(forwardingTo: relay)
        let fm = FileManager.default
        let support = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fm.temporaryDirectory
        dirs = Dirs(support: support, staging: support.appendingPathComponent("staging", isDirectory: true),
                    scratch: support.appendingPathComponent("engine-scratch", isDirectory: true),
                    downloads: fm.temporaryDirectory.appendingPathComponent("downloads", isDirectory: true))
        super.init()
    }

    // MARK: - lifecycle

    /// Builds the engine. Call from `application(_:didFinishLaunchingWithOptions:)`: BGTaskScheduler
    /// handlers must be registered before it returns, and the background session must exist to
    /// receive the events of a relaunch.
    @MainActor
    func bootstrap() {
        let fm = FileManager.default
        for d in [dirs.staging, dirs.scratch] {
            try? fm.createDirectory(at: d, withIntermediateDirectories: true)
        }
        // Keychain items survive uninstalling; the engine database does not. A fresh install
        // starts unpaired instead of holding credentials for an index that is gone.
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: Self.installedKey) {
            try? store.wipe()
            defaults.set(true, forKey: Self.installedKey)
        }
        var excluded = dirs.support
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? excluded.setResourceValues(values)

        uploader = BackgroundSessionUploader(pinning: pinning, clientHeader: clientHeader, scratchDir: dirs.scratch)
        uploader.cellularAllowed = { [weak self] in !(self?.currentSettings().wifiOnly ?? false) }
        let conditions = self.conditions
        library.networkAccessAllowed = { [weak self] in
            !(self?.currentSettings().wifiOnly ?? false) || conditions.onUnmeteredNetwork
        }

        bgTasks = BGTasks(runtime: { [weak self] in self?.engine() },
                          settings: { [weak self] in self?.currentSettings() ?? EngineSettings() })
        bgTasks.beforeRun = { await conditions.waitForFirstPath(timeoutMs: 2_000) }
        bgTasks.register()
        // Opens the database and installs the engine's completion handler, so completions
        // delivered on a relaunch apply.
        _ = engine()?.controller()

        watcher = LibraryWatcher { [weak self] in self?.engine()?.runNow() }
        watcher.registerIfAllowed()

        conditions.onNetworkChange = { [weak self] in
            guard let self, let runtime = self.engine() else { return }
            runtime.controller()?.onNetworkChanged()
            DispatchQueue.main.async {
                if UIApplication.shared.applicationState == .active { runtime.runNow() }
            }
        }
        conditions.start()
        bgTasks.scheduleRefresh()
    }

    /// The runtime, opening the engine database first when it is not open yet (nil when it
    /// cannot be opened now).
    private func engine() -> EngineRuntime? {
        engineLock.lock()
        defer { engineLock.unlock() }
        if let runtime { return runtime }
        let file = dirs.support.appendingPathComponent("engine.sqlite")
        guard let uploader, let opened = try? EngineDB(path: file.path) else { return nil }
        let header = clientHeader
        let rt = EngineRuntime(
            store: store, library: library, uploader: uploader, events: notifier, db: opened,
            config: EngineConfig(stagingDir: dirs.staging), appVersion: appVersion, pinning: pinning,
            makeHTTP: { p in EngineHTTP(session: EngineHTTP.makeSession(pinning: p, clientHeader: header), clientHeader: header) })
        let conditions = self.conditions
        rt.runBlocker = { s in conditions.blocker(s) }
        rt.onRunFinished = { [weak self] report in self?.runFinished(report) }
        db = opened
        runtime = rt
        return rt
    }

    /// The runtime, or the `internal` error the app shows when the database cannot be opened.
    private func rt() throws -> EngineRuntime {
        guard let r = engine() else {
            throw PigeonError(code: "internal", message: "The engine database could not be opened", details: nil)
        }
        return r
    }

    private func openDB() throws -> EngineDB {
        _ = try rt()
        engineLock.lock()
        defer { engineLock.unlock() }
        guard let db else { throw PigeonError(code: "internal", message: "The engine database could not be opened", details: nil) }
        return db
    }

    private func currentSettings() -> EngineSettings {
        engineLock.lock()
        let db = self.db
        engineLock.unlock()
        return db.map { SettingsRepo(db: $0).get() } ?? EngineSettings()
    }

    func attach(messenger: FlutterBinaryMessenger) {
        EngineHostApiSetup.setUp(binaryMessenger: messenger, api: self)
        relay.attach(EngineEventsApi(binaryMessenger: messenger))
    }

    /// `application(_:handleEventsForBackgroundURLSession:completionHandler:)`.
    func handleBackgroundSessionEvents(identifier: String, completionHandler: @escaping () -> Void) -> Bool {
        guard identifier == BackgroundSessionUploader.identifier, let uploader else { return false }
        uploader.handleEvents(completionHandler: completionHandler)
        return true
    }

    /// Schedules what comes after a run: background tasks, and in the foreground a follow-up run
    /// when the next attempt is near.
    private func runFinished(_ report: RunReport) {
        bgTasks.runFinished(report)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.followUp?.cancel()
            self.followUp = nil
            guard UIApplication.shared.applicationState == .active, let next = report.nextAttemptAtMs else { return }
            let delay = Double(next) / 1000 - Date().timeIntervalSince1970
            guard delay < 15 * 60 else { return }
            let work = DispatchWorkItem { [weak self] in self?.engine()?.runNow() }
            self.followUp = work
            DispatchQueue.main.asyncAfter(deadline: .now() + max(delay, 1), execute: work)
        }
    }

    // MARK: - reply plumbing

    /// Runs `body` off the main thread and replies on it, with errors mapped to the codes the app reads.
    private func respond<T>(_ completion: @escaping (Result<T, Error>) -> Void, _ body: @escaping () async throws -> T) {
        Task {
            let result: Result<T, Error>
            do {
                result = .success(try await body())
            } catch {
                result = .failure(PigeonMapping.error(error))
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    private func controller() throws -> EngineController {
        guard let c = try rt().controller() else { throw RuntimeError.notPaired }
        return c
    }

    // MARK: - pairing

    func pair(req: PairRequest, completion: @escaping (Result<PairResult, Error>) -> Void) {
        respond(completion) { [weak self] in
            guard let self else { throw RuntimeError.notPaired }
            return PigeonMapping.pairResult(try await self.rt().pair(PigeonMapping.pairInput(req)))
        }
    }

    func trustOnFirstUse(serverUrl: String, completion: @escaping (Result<ServerIdentity, Error>) -> Void) {
        let header = clientHeader
        respond(completion) {
            PigeonMapping.identity(try await TrustOnFirstUse.probe(serverUrl: serverUrl, clientHeader: header))
        }
    }

    /// M§3: nothing scheduled survives (the follow-up run, a debounced library run, background
    /// task requests, a continued "Back up now"), uploads in the session are cancelled, then the
    /// runtime logs out (at most 5 s), wipes the credentials and clears the index once every run
    /// has stopped.
    func unpair(completion: @escaping (Result<Void, Error>) -> Void) {
        respond(completion) { [weak self] in
            guard let self else { return }
            await MainActor.run {
                self.followUp?.cancel()
                self.followUp = nil
            }
            self.watcher?.cancelPending()
            self.bgTasks?.cancelAll()
            self.uploader?.cancelAll()
            if let runtime = self.engine() {
                await runtime.unpair()
            } else {
                // No database to clear: at least nothing stays paired.
                try? self.store.wipe()
            }
            self.notifier.reset()
        }
    }

    func getAccessToken(completion: @escaping (Result<String, Error>) -> Void) {
        respond(completion) { [weak self] in
            guard let self else { throw RuntimeError.notPaired }
            return try await self.rt().accessToken()
        }
    }

    func serverInfo(completion: @escaping (Result<ServerConnection?, Error>) -> Void) {
        respond(completion) { [weak self] in
            guard let self else { return nil }
            return try self.rt().connection().map(PigeonMapping.connection)
        }
    }

    // MARK: - control

    func start(completion: @escaping (Result<Void, Error>) -> Void) {
        respond(completion) { [weak self] in
            guard let self else { return }
            _ = await PhotoKitLibrary.requestAccess()
            self.watcher?.registerIfAllowed()
            // The user is starting backup: the moment to ask about "backup paused" alerts.
            await PauseNotifier.requestAuthorization()
            let runtime = try self.rt()
            guard let c = runtime.controller() else { throw RuntimeError.notPaired }
            await c.start()
            runtime.runNow()
        }
    }

    func pause(reason: PauseReason, completion: @escaping (Result<Void, Error>) -> Void) {
        respond(completion) { [weak self] in
            guard let self else { return }
            try await self.controller().pause(PigeonMapping.pauseReason(reason))
        }
    }

    func runNow(completion: @escaping (Result<Void, Error>) -> Void) {
        respond(completion) { [weak self] in
            guard let self else { return }
            _ = try self.controller()
            if await self.startContinued() { return }
            try self.rt().runNow()
        }
    }

    /// "Back up now" as a continued processing task on iOS 26, so it survives leaving the app.
    @MainActor
    private func startContinued() -> Bool {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            return bgTasks.startContinued(title: "Backing up", subtitle: "PicTunnel is backing up your photos")
        }
        #endif
        return false
    }

    func getStatus(completion: @escaping (Result<BackupStatus, Error>) -> Void) {
        respond(completion) { [weak self] in
            let access = PhotoKitLibrary.access()
            guard let self else { return PigeonMapping.emptyStatus(access: access) }
            guard let c = try self.rt().controller() else { return PigeonMapping.emptyStatus(access: access) }
            return PigeonMapping.status(await c.status(), access: access)
        }
    }

    func getSettings(completion: @escaping (Result<EngineSettings, Error>) -> Void) {
        respond(completion) { [weak self] in
            guard let self else { throw RuntimeError.notPaired }
            return PigeonMapping.settings(SettingsRepo(db: try self.openDB()).get())
        }
    }

    func setSettings(s: EngineSettings, completion: @escaping (Result<Void, Error>) -> Void) {
        respond(completion) { [weak self] in
            guard let self else { return }
            let repo = SettingsRepo(db: try self.openDB())
            let next = PigeonMapping.settings(s, keeping: repo.get())
            if let c = try self.rt().controller() {
                try await c.setSettings(next)
            } else {
                try repo.set(next)
            }
        }
    }

    // MARK: - library

    func listAlbums(completion: @escaping (Result<[AlbumInfo], Error>) -> Void) {
        respond(completion) { [library] in library.albums().map(PigeonMapping.album) }
    }

    func listPhoneItems(req: PageRequest, completion: @escaping (Result<PhoneItemPage, Error>) -> Void) {
        respond(completion) { [weak self] in
            guard let self else { throw RuntimeError.notPaired }
            let page = try await self.controller().listPhoneItems(afterKey: req.afterKey, limit: Int(req.limit))
            return PigeonMapping.page(page)
        }
    }

    func phoneThumbnail(localId: String, sizePx: Int64, completion: @escaping (Result<FlutterStandardTypedData, Error>) -> Void) {
        respond(completion) { [library] in
            FlutterStandardTypedData(bytes: try await library.thumbnail(localId: localId, sizePx: Int(sizePx)))
        }
    }

    // MARK: - attention, activity, free up space

    func listAttention(completion: @escaping (Result<[AttentionItem], Error>) -> Void) {
        respond(completion) { [weak self] in
            guard let self else { throw RuntimeError.notPaired }
            return try await self.controller().listAttention().map(PigeonMapping.attention)
        }
    }

    func retry(localIds: [String], completion: @escaping (Result<Void, Error>) -> Void) {
        respond(completion) { [weak self] in
            guard let self else { return }
            try await self.controller().retry(localIds)
            try self.rt().runNow()
        }
    }

    func listActivity(limit: Int64, completion: @escaping (Result<[ActivityEntry], Error>) -> Void) {
        respond(completion) { [weak self] in
            guard let self else { throw RuntimeError.notPaired }
            return try await self.controller().listActivity(limit: Int(limit)).map(PigeonMapping.activity)
        }
    }

    func freeUpSpace(localIds: [String]?, completion: @escaping (Result<FreeUpResult, Error>) -> Void) {
        respond(completion) { [weak self] in
            guard let self else { throw RuntimeError.notPaired }
            let result = try await self.controller().freeUpSpace(localIds, deleter: PhotoKitDeleter())
            return PigeonMapping.freeUp(result)
        }
    }

    func undoSkip(sha256: String, completion: @escaping (Result<Void, Error>) -> Void) {
        respond(completion) { [weak self] in
            guard let self else { return }
            guard try await self.controller().undoSkip(sha256) else {
                throw PigeonError(code: "undo_failed", message: "The server did not confirm", details: nil)
            }
            try self.rt().runNow()
        }
    }

    func saveToGallery(assetId: String, filename: String, mime: String, completion: @escaping (Result<String, Error>) -> Void) {
        respond(completion) { [weak self] in
            guard let self else { throw RuntimeError.notPaired }
            return try await GalleryWriter(runtime: self.rt(), tmpDir: self.dirs.downloads)
                .save(assetId: assetId, filename: filename, mime: mime)
        }
    }

    func discoverServers(timeoutMs: Int64, completion: @escaping (Result<[String], Error>) -> Void) {
        respond(completion) { await BonjourDiscovery.discover(timeoutMs: Int(timeoutMs)) }
    }

    // MARK: - media access

    /// "Allow full access": asks for read/write access when it was never asked; with limited or
    /// denied access (only Settings can grant full access then) opens the app's Settings page.
    /// Then pushes a fresh status (its `mediaAccess` is read at delivery) and, when more became
    /// readable, starts a run so the newly allowed photos are backed up.
    func requestMediaAccess(completion: @escaping (Result<MediaAccess, Error>) -> Void) {
        respond(completion) { [weak self] in
            let before = PhotoKitLibrary.access()
            switch before {
            case .full:
                break
            case .notDetermined:
                _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            case .limited, .denied:
                await MainActor.run {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
            }
            let after = PhotoKitLibrary.access()
            self?.watcher?.registerIfAllowed()
            if let self, let runtime = self.engine(), let c = runtime.controller() {
                self.relay.status(await c.status())
                if after != before, after == .full || after == .limited { runtime.runNow() }
            }
            return PigeonMapping.mediaAccess(after)
        }
    }
}
