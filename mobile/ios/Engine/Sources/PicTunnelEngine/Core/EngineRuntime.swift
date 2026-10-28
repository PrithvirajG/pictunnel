import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The paired server as the app shows it (the Pigeon `ServerConnection`).
public struct RuntimeConnection: Equatable, Sendable {
    public var serverId: String
    public var name: String
    public var activeEndpoint: String
    public var onLan: Bool
    public var fp16: String
}

/// Why a call that needs a paired engine failed.
public enum RuntimeError: Error, Equatable, Sendable {
    case notPaired
    /// The credentials were wiped (refresh token reused, device revoked): pair again.
    case needsRepair
    /// The token refresh failed for now (network, server error); try again later.
    case transient
}

/// Owns the engine for the current pairing (M§3, M§6): builds the `EngineController` from the
/// stored credentials, pairs and unpairs, and runs the pipeline. The platform layer (the Pigeon
/// host, BGTaskScheduler handlers, the background session) goes through it, so there is one
/// controller, one upload tracker and one run at a time per process.
///
/// Platform pieces come in from outside: the photo library, the background uploader, the
/// credential store and the pinning delegate the uploader's session shares with the engine.
public final class EngineRuntime: @unchecked Sendable {
    public static let serverIdKey = "paired_server_id"
    public static let serverNameKey = "paired_server_name"

    private let store: CredentialStore
    private let library: any PhotoLibrary
    private let uploader: any BackgroundUploader
    private let events: any EngineEvents
    private let db: EngineDB
    private let config: EngineConfig
    private let appVersion: String
    private let clock: any Clock
    private let pinning: PinningDelegate
    private let makeHTTP: @Sendable (PinningDelegate) -> EngineHTTP

    private let lock = NSLock()
    private var stack: Stack?
    /// Bumped on every pair and unpair; `needsRepair` fires once per generation.
    private var generation = 0
    private var repairedGeneration = -1
    private var kick: Task<Void, Never>?
    private var _onRunFinished: (@Sendable (RunReport) -> Void)?
    private var _runBlocker: (@Sendable (EngineSettings) -> PauseReason?)?

    private struct Stack {
        let controller: EngineController
        let client: ServerClient
        let creds: Credentials
    }

    /// - `pinning`: the delegate of every engine session (the background session included); it
    ///   reads the pin from `store` on each handshake.
    /// - `makeHTTP`: the JSON transport over a session whose TLS goes through the given delegate.
    public init(store: CredentialStore, library: any PhotoLibrary, uploader: any BackgroundUploader,
                events: any EngineEvents, db: EngineDB, config: EngineConfig, appVersion: String,
                clock: any Clock = SystemClock(), pinning: PinningDelegate,
                makeHTTP: @escaping @Sendable (PinningDelegate) -> EngineHTTP) {
        self.store = store
        self.library = library
        self.uploader = uploader
        self.events = events
        self.db = db
        self.config = config
        self.appVersion = appVersion
        self.clock = clock
        self.pinning = pinning
        self.makeHTTP = makeHTTP
    }

    /// `ios/<app version>`.
    public var clientHeader: String { EngineHTTP.clientHeader(version: appVersion) }

    /// Called after every pipeline run with its report, to schedule the next one.
    public var onRunFinished: (@Sendable (RunReport) -> Void)? {
        get { locked { _onRunFinished } }
        set { locked { _onRunFinished = newValue } }
    }

    /// Whether a run may start now under the settings (Wi-Fi only, charging only): nil when it
    /// may, else the reason it waits.
    public var runBlocker: (@Sendable (EngineSettings) -> PauseReason?)? {
        get { locked { _runBlocker } }
        set { locked { _runBlocker = newValue } }
    }

    // MARK: - the engine for the current pairing

    /// The controller, or nil when this phone is not paired (or the keychain is still locked).
    public func controller() -> EngineController? { current()?.controller }

    public var isPaired: Bool { current() != nil }

    private func current() -> Stack? {
        lock.lock()
        defer { lock.unlock() }
        if let stack { return stack }
        guard let creds = (try? store.load()) ?? nil else { return nil }
        let endpoints = Endpoints(creds.endpoints)
        let http = makeHTTP(pinning)
        let gen = generation
        let auth = AuthManager(store: store, http: http, endpoints: endpoints,
                               onNeedsRepair: { [weak self] in self?.repairNeeded(generation: gen) })
        let client = ServerClient(endpoints: endpoints, auth: auth, http: http)
        let relay = RuntimeEvents(inner: events) { [weak self] in self?.repairNeeded(generation: gen) }
        let controller = EngineController(db: db, library: library, uploader: uploader, client: client,
                                          settings: SettingsRepo(db: db), clock: clock, events: relay, config: config)
        let s = Stack(controller: controller, client: client, creds: creds)
        stack = s
        return s
    }

    /// Credentials are gone: drop the engine and tell the app once.
    private func repairNeeded(generation gen: Int) {
        let fire: Bool = locked {
            guard gen == generation, repairedGeneration != gen else { return false }
            repairedGeneration = gen
            stack = nil
            return true
        }
        if fire { events.needsRepair() }
    }

    // MARK: - pairing

    /// Pairs (P§6.3) and starts a fresh engine for the new credentials. Pairing with a different
    /// server than the index belongs to starts the index over; pairing again with the same server
    /// keeps it, so nothing is hashed twice. Throws `PairingError`.
    public func pair(_ input: PairInput) async throws -> Paired {
        kickTask()?.cancel()
        let paired = try await Pairer(store: store, appVersion: appVersion, makeHTTP: makeHTTP).pair(input)
        if (try? db.setting(Self.serverIdKey)) ?? nil != paired.serverId {
            try? db.reset()
            clearStaging()
        }
        try? db.setSetting(Self.serverIdKey, paired.serverId)
        try? db.setSetting(Self.serverNameKey, paired.serverName)
        // A pause for an untrusted certificate (or any other) belonged to the old pairing.
        try? SettingsRepo(db: db).clearPause()
        locked {
            stack = nil
            generation += 1
        }
        return paired
    }

    /// Unpairs (M§3): a best-effort `logout`, then the credentials, the engine database and the
    /// staging files are wiped. Uploads still running in the background session are the caller's
    /// to cancel.
    public func unpair() async {
        kickTask()?.cancel()
        if let client = current()?.client {
            _ = await Self.withDeadline(seconds: 5) { _ = await client.logout() }
        }
        try? store.wipe()
        try? db.reset()
        clearStaging()
        locked {
            stack = nil
            generation += 1
        }
    }

    /// The current access token, refreshed first when it is about to expire (M§3 `getAccessToken`).
    public func accessToken() async throws -> String {
        guard let s = current() else { throw RuntimeError.notPaired }
        do {
            return try await s.client.auth.accessToken()
        } catch AuthError.needsRepair {
            throw RuntimeError.needsRepair
        } catch {
            throw RuntimeError.transient
        }
    }

    public func connection() -> RuntimeConnection? {
        guard let s = current() else { return nil }
        let active = s.client.endpoints.active
        let name = ((try? db.setting(Self.serverNameKey)) ?? nil) ?? "PicTunnel"
        return RuntimeConnection(serverId: s.creds.serverId, name: name, activeEndpoint: active.absoluteString,
                                 onLan: Endpoints.isLan(active.host ?? ""), fp16: String(s.creds.pinSpki.prefix(16)))
    }

    /// The JSON client of the current pairing (downloads for `saveToGallery`).
    public func client() -> ServerClient? { current()?.client }

    // MARK: - runs

    /// One pipeline run, unless unpaired or the settings' conditions are not met (nil then).
    @discardableResult
    public func runOnce(budget: RunBudget) async -> RunReport? {
        guard let c = controller() else { return nil }
        if let blocker = runBlocker, blocker(await c.getSettings()) != nil { return nil }
        let report = await c.runOnce(budget: budget)
        onRunFinished?(report)
        return report
    }

    /// Starts a run now unless one started this way is still going ("Back up now", `start()`).
    public func runNow() {
        locked {
            guard kick == nil else { return }
            kick = Task { [weak self] in
                await self?.runOnce(budget: RunBudget())
                self?.locked { self?.kick = nil }
            }
        }
    }

    private func kickTask() -> Task<Void, Never>? { locked { kick } }

    private func clearStaging() {
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: config.stagingDir.path)) ?? [] {
            try? fm.removeItem(at: config.stagingDir.appendingPathComponent(name))
        }
    }

    /// Runs `body`, giving up waiting after `seconds` (the work itself is cancelled).
    static func withDeadline(seconds: Double, _ body: @escaping @Sendable () async -> Void) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await body()
                return true
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

/// Forwards engine events; a repair goes through the runtime, so it fires once per pairing.
private final class RuntimeEvents: EngineEvents, @unchecked Sendable {
    private let inner: any EngineEvents
    private let repair: @Sendable () -> Void

    init(inner: any EngineEvents, repair: @escaping @Sendable () -> Void) {
        self.inner = inner
        self.repair = repair
    }

    func status(_ s: BackupStatus) { inner.status(s) }
    func itemChanged(_ i: Item) { inner.itemChanged(i) }
    func needsRepair() { repair() }
}
