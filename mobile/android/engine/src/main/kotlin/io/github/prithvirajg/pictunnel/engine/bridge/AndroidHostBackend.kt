package io.github.prithvirajg.pictunnel.engine.bridge

import android.content.Context
import io.github.prithvirajg.pictunnel.engine.core.AttentionItem
import io.github.prithvirajg.pictunnel.engine.core.BackupStatus
import io.github.prithvirajg.pictunnel.engine.core.EngineSettings
import io.github.prithvirajg.pictunnel.engine.core.FreeUpResult
import io.github.prithvirajg.pictunnel.engine.core.PhoneItemPage
import io.github.prithvirajg.pictunnel.engine.model.PauseReason
import io.github.prithvirajg.pictunnel.engine.net.Endpoints
import io.github.prithvirajg.pictunnel.engine.pairing.PairResult
import io.github.prithvirajg.pictunnel.engine.pairing.Pairer
import io.github.prithvirajg.pictunnel.engine.pairing.ServerFingerprint
import io.github.prithvirajg.pictunnel.engine.pairing.TrustOnFirstUse
import io.github.prithvirajg.pictunnel.engine.platform.Album
import io.github.prithvirajg.pictunnel.engine.platform.GalleryWriter
import io.github.prithvirajg.pictunnel.engine.platform.IntentSenderLauncher
import io.github.prithvirajg.pictunnel.engine.platform.MediaLibrary
import io.github.prithvirajg.pictunnel.engine.platform.MediaStoreDeleter
import io.github.prithvirajg.pictunnel.engine.platform.NsdDiscovery
import io.github.prithvirajg.pictunnel.engine.sched.EngineRuntime
import io.github.prithvirajg.pictunnel.engine.sched.Scheduling
import io.github.prithvirajg.pictunnel.engine.store.ActivityEntity
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.withTimeoutOrNull
import java.util.concurrent.atomic.AtomicReference

/**
 * The real [HostBackend]: the paired [EngineServices.Session]'s controller,
 * [Scheduling] and [EngineRuntime] for runs, and the platform adapters.
 * [launcher] is the current activity's delete-request launcher (free up
 * space needs the OS dialog), null while no activity is attached.
 */
class AndroidHostBackend(
    context: Context,
    private val services: EngineServices = EngineServices.get(context),
    private val launcher: () -> IntentSenderLauncher?,
) : HostBackend {
    private val app = context.applicationContext
    private val library = MediaLibrary(app)

    private fun session() = services.session() ?: throw HostException(NOT_PAIRED, "This phone is not paired")

    private fun controller() = session().controller

    override suspend fun pairQr(
        qrUri: String,
        deviceName: String,
    ): Paired = afterPair(services.endSession { pairer().pair(qrUri, deviceName) })

    override suspend fun pairManual(
        serverUrl: String,
        code: String,
        pin: String,
        deviceName: String,
    ): Paired = afterPair(services.endSession { pairer().pairManual(serverUrl, code, pin, deviceName) })

    private fun pairer() = Pairer(services.store, services.clientHeader, services.appVersion, services.pairingHttp)

    /**
     * Credentials are stored (the old session ended first): build the new
     * session and record the server; a different server starts a fresh index.
     */
    private suspend fun afterPair(r: PairResult): Paired {
        val s = session()
        return Paired(r, services.account.adoptServer(r.serverId) { s.client.serverInfo().name })
    }

    override suspend fun trustOnFirstUse(serverUrl: String): ServerFingerprint =
        TrustOnFirstUse(services.clientHeader, services.pairingHttp).probe(serverUrl)

    /**
     * M§3: a best-effort `logout` (at most [LOGOUT_TIMEOUT_MS], failures
     * ignored), no more background work, then the credentials are wiped under
     * the refresh lock (an in-flight refresh cannot restore them) and the
     * index, cursors, activity log and server identity are cleared. Cached
     * hashes stay.
     */
    override suspend fun unpair() {
        try {
            services.session()?.let { s -> withTimeoutOrNull(LOGOUT_TIMEOUT_MS) { s.client.logout() } }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            // Offline or already revoked: unpairing is local first.
        }
        Scheduling.cancelAll(app)
        services.endSession { services.store.wipe() }
        services.account.forget()
    }

    override suspend fun accessToken(): String = session().auth.accessToken()

    override suspend fun connection(): Connection? {
        val s = services.session() ?: return null
        val active = s.endpoints.active
        return Connection(
            serverId = s.credentials.serverId,
            name = services.settings.serverName() ?: DEFAULT_NAME,
            activeEndpoint = active.toString().trimEnd('/'),
            onLan = Endpoints.isLan(active.host),
            fp16 = s.credentials.pinSpki.take(16),
        )
    }

    override suspend fun start() {
        val c = controller()
        c.start()
        Scheduling.ensure(app)
        Scheduling.requestSync(app, c)
    }

    override suspend fun pause(reason: PauseReason) {
        controller().pause(reason)
        EngineRuntime.runs.cancelRuns()
    }

    /** "Back up now", also the banner's Resume: a user pause is lifted, server pauses stay. */
    override suspend fun runNow() {
        val c = controller()
        if (c.pauseState()?.reason == PauseReason.User) c.start()
        Scheduling.runNow(app, c)
    }

    override suspend fun status(): BackupStatus = controller().status()

    override suspend fun settings(): EngineSettings = controller().getSettings()

    override suspend fun setSettings(s: EngineSettings) {
        controller().setSettings(s)
        EngineRuntime.onSettingsChanged(app)
    }

    override suspend fun albums(): List<Album> = library.albums()

    override suspend fun phoneItems(
        afterKey: String?,
        limit: Int,
    ): PhoneItemPage = controller().listPhoneItems(afterKey, limit)

    override suspend fun thumbnail(
        localId: String,
        sizePx: Int,
    ): ByteArray = library.thumbnail(localId, sizePx)

    override suspend fun attention(): List<AttentionItem> = controller().listAttention()

    override suspend fun retry(localIds: List<String>) {
        val c = controller()
        c.retry(localIds)
        Scheduling.requestSync(app, c)
    }

    override suspend fun activity(limit: Int): List<ActivityEntity> = controller().listActivity(limit)

    override suspend fun freeUpSpace(localIds: List<String>?): FreeUpResult {
        session()
        val l = launcher() ?: throw HostException("no_activity", "Open PicTunnel to free up space")
        return EngineRuntime.freeUpSpace(app, localIds, MediaStoreDeleter(app, l))
    }

    override suspend fun undoSkip(sha256: String): Boolean {
        val c = controller()
        val ok = c.undoSkip(sha256)
        if (ok) Scheduling.requestSync(app, c)
        return ok
    }

    override suspend fun saveToGallery(
        assetId: String,
        filename: String,
        mime: String,
    ): String = GalleryWriter(app, session().client).saveToGallery(assetId, filename, mime)

    override suspend fun discover(timeoutMs: Long): List<String> {
        val latest = AtomicReference<List<String>>(emptyList())
        withTimeoutOrNull(timeoutMs) {
            NsdDiscovery(app).discover().collect { servers -> latest.set(servers.map { it.url }.distinct()) }
        }
        return latest.get()
    }

    companion object {
        const val NOT_PAIRED = "not_paired"
        const val LOGOUT_TIMEOUT_MS = 5_000L
        private const val DEFAULT_NAME = Account.DEFAULT_NAME
    }
}
