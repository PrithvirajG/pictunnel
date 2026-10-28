package io.github.prithvirajg.pictunnel.engine.bridge

import android.content.Context
import android.os.SystemClock
import io.github.prithvirajg.pictunnel.engine.core.Clock
import io.github.prithvirajg.pictunnel.engine.core.EngineController
import io.github.prithvirajg.pictunnel.engine.core.SettingsRepo
import io.github.prithvirajg.pictunnel.engine.cred.CredentialStore
import io.github.prithvirajg.pictunnel.engine.cred.Credentials
import io.github.prithvirajg.pictunnel.engine.net.AuthManager
import io.github.prithvirajg.pictunnel.engine.net.EngineHttp
import io.github.prithvirajg.pictunnel.engine.net.Endpoints
import io.github.prithvirajg.pictunnel.engine.net.ServerClient
import io.github.prithvirajg.pictunnel.engine.platform.ContentMediaSource
import io.github.prithvirajg.pictunnel.engine.platform.KeystoreCredentialStore
import io.github.prithvirajg.pictunnel.engine.platform.MediaStoreScanner
import io.github.prithvirajg.pictunnel.engine.sched.EngineRuntime
import io.github.prithvirajg.pictunnel.engine.store.EngineDb
import okhttp3.OkHttpClient

/**
 * The process-wide engine graph (M§4): the database, the credential store and
 * the events relay live as long as the process; a [Session] (network client,
 * auth and [EngineController]) exists while the phone is paired and is rebuilt
 * after pairing, unpairing or a credential wipe.
 */
class EngineServices private constructor(
    context: Context,
) {
    private val app = context.applicationContext

    val db: EngineDb by lazy { EngineDb.open(app) }
    val store: CredentialStore by lazy { KeystoreCredentialStore.create(app) }
    val settings: SettingsRepo by lazy { SettingsRepo(db.settings()) }
    val relay = EventsRelay(onNeedsRepair = ::drop)
    val account: Account by lazy { Account(db, settings, EngineRuntime.runs) }

    /** One connection pool and dispatcher for the pairing probes (trust on first use, redeem). */
    val pairingHttp: OkHttpClient by lazy { OkHttpClient() }

    val appVersion: String =
        runCatching { app.packageManager.getPackageInfo(app.packageName, 0).versionName }.getOrNull() ?: "0.0.0"

    /** `PicTunnel-Client` value for every request (P§3). */
    val clientHeader = "android/$appVersion"

    class Session(
        val credentials: Credentials,
        val endpoints: Endpoints,
        val auth: AuthManager,
        val client: ServerClient,
        val controller: EngineController,
    )

    @Volatile private var session: Session? = null

    /** The paired session, built from the stored credentials; null while not paired. */
    @Synchronized
    fun session(): Session? {
        session?.let { return it }
        val creds = store.load() ?: return null
        val endpoints = Endpoints(creds.endpoints)
        val http = EngineHttp.newClient(creds.pinSpki, clientHeader)
        val auth = AuthManager(store, http, SystemClock::elapsedRealtime, clientHeader, endpoints)
        auth.onNeedsRepair = { relay.needsRepair() }
        val client = ServerClient(endpoints, auth, http, clientHeader)
        val controller =
            EngineController(
                db,
                MediaStoreScanner(app, db) { settings.get() },
                ContentMediaSource(app),
                client,
                settings,
                Clock.System,
                relay,
            )
        return Session(creds, endpoints, auth, client, controller).also { session = it }
    }

    /**
     * Ends the current session before credentials change: waits for its
     * in-flight refresh, then runs [block] (the wipe or the new pairing's
     * save) under the refresh lock, so a late refresh cannot overwrite it.
     */
    suspend fun <T> endSession(block: suspend () -> T): T {
        val s =
            synchronized(this) {
                val current = session
                session = null
                current
            }
        return if (s != null) s.auth.close(block) else block()
    }

    /** Forgets the session (credentials changed or wiped); the next [session] call rebuilds it. */
    @Synchronized
    fun drop() {
        session = null
    }

    companion object {
        @Volatile private var instance: EngineServices? = null

        fun get(context: Context): EngineServices =
            instance ?: synchronized(this) { instance ?: EngineServices(context).also { instance = it } }

        /**
         * Call from `Application.onCreate`: workers, the foreground service and
         * receivers reach the paired controller through [EngineRuntime].
         */
        fun installRuntime(context: Context) {
            EngineRuntime.install { ctx -> get(ctx).session()?.controller }
            EngineRuntime.start(context)
        }
    }
}
