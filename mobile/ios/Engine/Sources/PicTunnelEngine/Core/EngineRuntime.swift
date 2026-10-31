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
    /// The full pinned SPKI SHA-256 (unpadded base64url); Flutter pins its browse client to it.
    public var fpFull: String
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
/// Every run goes through one `RunGate`, so pairing and unpairing stop the runs and wait for
/// them (the Kotlin `RunCoordinator.preempt`). While a pairing or an unpairing is changing the
/// credentials the runtime is "ending": no engine is handed out or rebuilt (the Kotlin
/// `SessionSlot`), so nothing works from credentials about to be wiped or replaced, and a
/// `needsRepair` from the old session never reaches the app.
///
/// Platform pieces come in from outside: the photo library, the background uploader, the
/// credential store and the pinning delegate the uploader's session shares with the engine.
public final class EngineRuntime: @unchecked Sendable {
    public static let serverIdKey = "paired_server_id"
    public static let serverNameKey = "paired_server_name"
    /// M§3: the best-effort logout of an unpair waits at most this long.
    public static let logoutTimeoutSeconds: Double = 5

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
    private let gate = RunGate()

    private let lock = NSLock()
    private var stack: Stack?
    /// Raised while a pairing or an unpairing changes the credentials: `current()` is nil then.
    private var ending = 0
    /// Bumped whenever a session ends; `needsRepair` fires once per generation, and never for
    /// a session that has already ended.
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

    /// Called after every pipeline run with its report, to schedule the next one. Not called for
    /// a run that a pairing or an unpairing stopped.
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

    /// The controller, or nil when this phone is not paired (or the keychain is still locked, or
    /// a pairing or an unpairing is in progress).
    public func controller() -> EngineController? { current()?.controller }

    public var isPaired: Bool { current() != nil }

    /// Runs in progress (for tests and diagnostics).
    public var runningRuns: Int { gate.running }

    private func current() -> Stack? {
        locked {
            if ending > 0 { return nil }
            return stack ?? buildLocked()
        }
    }

    /// Builds and caches the stack from the stored credentials. Call with `lock` held.
    private func buildLocked() -> Stack? {
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

    /// Credentials are gone: drop the engine and tell the app once. Never while a pairing or an
    /// unpairing is ending the session, and never for a session that already ended.
    private func repairNeeded(generation gen: Int) {
        let fire: Bool = locked {
            guard ending == 0, gen == generation, repairedGeneration != gen else { return false }
            repairedGeneration = gen
            stack = nil
            return true
        }
        if fire { events.needsRepair() }
    }

    /// Starts ending the current session: from now on `current()` is nil and no stack is built.
    /// Returns the session that was current (built first when `build`, for the logout).
    private func beginEnding(build: Bool) -> Stack? {
        locked {
            let old = ending == 0 ? (stack ?? (build ? buildLocked() : nil)) : stack
            ending += 1
            generation += 1
            stack = nil
            return old
        }
    }

    private func finishEnding() {
        locked {
            ending -= 1
            // Nothing is built while ending; drop anything that slipped in anyway.
            stack = nil
        }
    }

    // MARK: - pairing

    /// Pairs (P§6.3) and starts a fresh engine for the new credentials. The old session is ended
    /// first and every run is stopped and awaited, so two pipelines never work on one database.
    /// Pairing with a different server than the index belongs to clears the old index (cached
    /// hashes and settings stay); pairing again with the same server keeps it, so nothing is hashed
    /// twice. Throws `PairingError`; a failed pairing leaves the old credentials and index as they were.
    public func pair(_ input: PairInput) async throws -> Paired {
        let old = beginEnding(build: false)
        defer { finishEnding() }
        if let old { _ = await old.client.auth.close {} }
        return try await gate.preempt {
            let paired = try await Pairer(store: store, appVersion: appVersion, makeHTTP: makeHTTP).pair(input)
            adoptServer(paired)
            return paired
        }
    }

    /// Credentials for `paired` were just stored: record the server, and start a fresh index when
    /// it is not the server the index belongs to. Runs under the gate.
    private func adoptServer(_ paired: Paired) {
        let previous = (try? db.setting(Self.serverIdKey)) ?? nil
        if previous != paired.serverId {
            if previous != nil {
                try? db.clearIndex(removingSettings: SettingsRepo.pairingStateKeys)
            }
            clearStaging()
        }
        try? db.setSetting(Self.serverIdKey, paired.serverId)
        try? db.setSetting(Self.serverNameKey, paired.serverName)
        // A pause for an untrusted certificate (or any other) belonged to the old pairing.
        try? SettingsRepo(db: db).clearPause()
    }

    /// Unpairs (M§3), mirroring the Kotlin `unpair`:
    /// 1. a best-effort `logout`, waited for at most `logoutTimeoutSeconds` (never longer, even
    ///    when the endpoint does not answer);
    /// 2. the session is closed and the credentials wiped under its refresh single flight, so a
    ///    refresh still in flight cannot restore them;
    /// 3. every run is stopped and awaited, then the index, scan token, activity log, pause and
    ///    server identity are cleared (cached hashes and the user's settings stay), and the
    ///    staging files removed.
    /// Uploads still running in the background session are the caller's to cancel.
    public func unpair() async {
        let old = beginEnding(build: true)
        defer { finishEnding() }
        if let client = old?.client {
            _ = await Self.withDeadline(seconds: Self.logoutTimeoutSeconds) { _ = await client.logout() }
        }
        let store = self.store
        if let auth = old?.client.auth {
            _ = await auth.close { try? store.wipe() }
        } else {
            try? store.wipe()
        }
        await gate.preempt {
            try? db.clearIndex(removingSettings: SettingsRepo.pairingStateKeys + [Self.serverIdKey, Self.serverNameKey])
            clearStaging()
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
                                 onLan: Endpoints.isLan(active.host ?? ""), fp16: String(s.creds.pinSpki.prefix(16)),
                                 fpFull: s.creds.pinSpki)
    }

    /// The JSON client of the current pairing (downloads for `saveToGallery`).
    public func client() -> ServerClient? { current()?.client }

    // MARK: - runs

    /// One pipeline run through the gate, unless unpaired or the settings' conditions are not met
    /// (nil then, and also when a pairing or an unpairing stopped it). Cancelling the caller (a
    /// background task expiring) cancels the run.
    @discardableResult
    public func runOnce(budget: RunBudget) async -> RunReport? {
        let report: RunReport? = await gate.run { [weak self] in
            guard let self, let c = self.controller() else { return nil }
            if let blocker = self.runBlocker, blocker(await c.getSettings()) != nil { return nil }
            return await c.runOnce(budget: budget)
        }
        if let report { onRunFinished?(report) }
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

    private func clearStaging() {
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: config.stagingDir.path)) ?? [] {
            try? fm.removeItem(at: config.stagingDir.appendingPathComponent(name))
        }
    }

    /// Runs `body` in a task of its own and waits at most `seconds` for it: true when it finished
    /// in time. On the deadline the body is cancelled and NOT awaited, so a request that ignores
    /// cancellation cannot hold the caller past the deadline.
    static func withDeadline(seconds: Double, _ body: @escaping @Sendable () async -> Void) async -> Bool {
        let race = Race()
        let work = Task {
            await body()
            race.finish(true)
        }
        let timer = Task {
            try? await Task.sleep(nanoseconds: UInt64(max(seconds, 0) * 1_000_000_000))
            race.finish(false)
        }
        let finished = await race.value()
        timer.cancel()
        if !finished { work.cancel() }
        return finished
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

/// The first of several racers to finish wins; later results are dropped.
private final class Race: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Bool?
    private var waiter: CheckedContinuation<Bool, Never>?

    func finish(_ value: Bool) {
        lock.lock()
        guard result == nil else {
            lock.unlock()
            return
        }
        result = value
        let w = waiter
        waiter = nil
        lock.unlock()
        w?.resume(returning: value)
    }

    func value() async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            lock.lock()
            if let result {
                lock.unlock()
                cont.resume(returning: result)
            } else {
                waiter = cont
                lock.unlock()
            }
        }
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
