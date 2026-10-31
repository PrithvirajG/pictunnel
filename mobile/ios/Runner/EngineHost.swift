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
final class EngineHost: NSObject, EngineHostApi {
    static let shared = EngineHost()

    private let appVersion: String
    private let clientHeader: String
    private let store = KeychainCredentialStore()
    private let library = PhotoKitLibrary()
    private let relay = EventsRelay()
    private let conditions = RunConditions()
    private let pinning: PinningDelegate
    private let dirs: Dirs
    private(set) var uploader: BackgroundSessionUploader!
    private var db: EngineDB!
    private var runtime: EngineRuntime!
    private var bgTasks: BGTasks!
    private var followUp: DispatchWorkItem?

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

        let dbFile = dirs.support.appendingPathComponent("engine.sqlite")
        var excluded = dirs.support
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? excluded.setResourceValues(values)
        db = (try? EngineDB(path: dbFile.path)) ?? (try! EngineDB.inMemory())

        uploader = BackgroundSessionUploader(pinning: pinning, clientHeader: clientHeader, scratchDir: dirs.scratch)
        let header = clientHeader
        runtime = EngineRuntime(
            store: store, library: library, uploader: uploader, events: relay, db: db,
            config: EngineConfig(stagingDir: dirs.staging), appVersion: appVersion, pinning: pinning,
            makeHTTP: { p in EngineHTTP(session: EngineHTTP.makeSession(pinning: p, clientHeader: header), clientHeader: header) })
        let settingsRepo = SettingsRepo(db: db)
        uploader.cellularAllowed = { !settingsRepo.get().wifiOnly }
        let conditions = self.conditions
        runtime.runBlocker = { s in conditions.blocker(s) }
        runtime.onRunFinished = { [weak self] report in self?.runFinished(report) }

        bgTasks = BGTasks(runtime: runtime, settings: { settingsRepo.get() })
        bgTasks.register()
        // Installs the engine's completion handler, so completions delivered on a relaunch apply.
        _ = runtime.controller()

        conditions.onNetworkChange = { [weak self] in
            guard let self else { return }
            self.runtime.controller()?.onNetworkChanged()
            DispatchQueue.main.async {
                if UIApplication.shared.applicationState == .active { self.runtime.runNow() }
            }
        }
        conditions.start()
        bgTasks.scheduleRefresh()
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
            let work = DispatchWorkItem { [weak self] in self?.runtime.runNow() }
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
        guard let c = runtime.controller() else { throw RuntimeError.notPaired }
        return c
    }

    // MARK: - pairing

    func pair(req: PairRequest, completion: @escaping (Result<PairResult, Error>) -> Void) {
        respond(completion) { [runtime] in
            PigeonMapping.pairResult(try await runtime!.pair(PigeonMapping.pairInput(req)))
        }
    }

    func trustOnFirstUse(serverUrl: String, completion: @escaping (Result<ServerIdentity, Error>) -> Void) {
        let header = clientHeader
        respond(completion) {
            PigeonMapping.identity(try await TrustOnFirstUse.probe(serverUrl: serverUrl, clientHeader: header))
        }
    }

    func unpair(completion: @escaping (Result<Void, Error>) -> Void) {
        respond(completion) { [runtime, uploader] in
            uploader?.cancelAll()
            await runtime!.unpair()
        }
    }

    func getAccessToken(completion: @escaping (Result<String, Error>) -> Void) {
        respond(completion) { [runtime] in try await runtime!.accessToken() }
    }

    func serverInfo(completion: @escaping (Result<ServerConnection?, Error>) -> Void) {
        respond(completion) { [runtime] in runtime!.connection().map(PigeonMapping.connection) }
    }

    // MARK: - control

    func start(completion: @escaping (Result<Void, Error>) -> Void) {
        respond(completion) { [runtime] in
            _ = await PhotoKitLibrary.requestAccess()
            guard let c = runtime!.controller() else { throw RuntimeError.notPaired }
            await c.start()
            runtime!.runNow()
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
            self.runtime.runNow()
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
        respond(completion) { [runtime] in
            let access = PhotoKitLibrary.access()
            guard let c = runtime!.controller() else { return PigeonMapping.emptyStatus(access: access) }
            return PigeonMapping.status(await c.status(), access: access)
        }
    }

    func getSettings(completion: @escaping (Result<EngineSettings, Error>) -> Void) {
        respond(completion) { [db] in PigeonMapping.settings(SettingsRepo(db: db!).get()) }
    }

    func setSettings(s: EngineSettings, completion: @escaping (Result<Void, Error>) -> Void) {
        respond(completion) { [weak self] in
            guard let self else { return }
            let current = SettingsRepo(db: self.db).get()
            let next = PigeonMapping.settings(s, keeping: current)
            if let c = self.runtime.controller() {
                try await c.setSettings(next)
            } else {
                try SettingsRepo(db: self.db).set(next)
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
            self.runtime.runNow()
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
            self.runtime.runNow()
        }
    }

    func saveToGallery(assetId: String, filename: String, mime: String, completion: @escaping (Result<String, Error>) -> Void) {
        respond(completion) { [weak self] in
            guard let self else { throw RuntimeError.notPaired }
            return try await GalleryWriter(runtime: self.runtime, tmpDir: self.dirs.downloads)
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
            if let self, let c = self.runtime?.controller() {
                self.relay.status(await c.status())
                if after != before, after == .full || after == .limited { self.runtime.runNow() }
            }
            return PigeonMapping.mediaAccess(after)
        }
    }
}
