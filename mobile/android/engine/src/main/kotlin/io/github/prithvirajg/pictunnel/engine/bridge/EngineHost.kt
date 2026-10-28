package io.github.prithvirajg.pictunnel.engine.bridge

import android.os.Handler
import android.os.Looper
import io.github.prithvirajg.pictunnel.engine.net.AuthException
import io.github.prithvirajg.pictunnel.engine.net.RefreshOutcome
import io.github.prithvirajg.pictunnel.engine.net.ServerException
import io.github.prithvirajg.pictunnel.engine.net.problem
import io.github.prithvirajg.pictunnel.engine.pairing.PairException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import java.io.IOException

/**
 * The Pigeon [EngineHostApi] on Android (M§3): every call runs as a coroutine
 * on [scope] against the [backend] and replies through [deliver] (the main
 * thread by default, where Flutter expects replies). Failures reach Flutter as
 * [FlutterError]s whose code the app's copy tables know (see [errorFor]).
 */
class EngineHost(
    private val backend: HostBackend,
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Default),
    private val deliver: (Runnable) -> Unit = MAIN::post,
) : EngineHostApi {
    private fun <T> call(
        callback: (Result<T>) -> Unit,
        block: suspend () -> T,
    ) {
        scope.launch {
            val result =
                try {
                    Result.success(block())
                } catch (e: CancellationException) {
                    Result.failure(FlutterError("cancelled", "The engine call was cancelled"))
                } catch (e: Throwable) {
                    Result.failure(errorFor(e))
                }
            deliver { callback(result) }
        }
    }

    override fun pair(
        req: PairRequest,
        callback: (Result<PairResult>) -> Unit,
    ) = call(callback) {
        val qr = req.qrUri
        val paired =
            if (qr != null) {
                backend.pairQr(qr, req.deviceName)
            } else {
                val url = req.serverUrl ?: throw HostException("invalid_request", "qrUri or serverUrl is required")
                val code = req.code ?: throw HostException("invalid_code", "a pairing code is required")
                val pin = req.pinnedFp ?: throw HostException("missing_fingerprint", "manual pairing needs the confirmed fingerprint")
                backend.pairManual(url, code, pin, req.deviceName)
            }
        PairResult(paired.result.serverId, paired.serverName, paired.result.userName, paired.result.deviceId)
    }

    override fun trustOnFirstUse(
        serverUrl: String,
        callback: (Result<ServerIdentity>) -> Unit,
    ) = call(callback) {
        val fp = backend.trustOnFirstUse(serverUrl)
        ServerIdentity(fp.serverId, fp.name, fp.fp16, fp.fpFull, fp.url)
    }

    override fun unpair(callback: (Result<Unit>) -> Unit) = call(callback) { backend.unpair() }

    override fun getAccessToken(callback: (Result<String>) -> Unit) = call(callback) { backend.accessToken() }

    override fun serverInfo(callback: (Result<ServerConnection?>) -> Unit) =
        call(callback) {
            backend.connection()?.let { ServerConnection(it.serverId, it.name, it.activeEndpoint, it.onLan, it.fp16) }
        }

    override fun start(callback: (Result<Unit>) -> Unit) = call(callback) { backend.start() }

    override fun pause(
        reason: PauseReason,
        callback: (Result<Unit>) -> Unit,
    ) = call(callback) { backend.pause(reason.toCore()) }

    override fun runNow(callback: (Result<Unit>) -> Unit) = call(callback) { backend.runNow() }

    override fun getStatus(callback: (Result<BackupStatus>) -> Unit) = call(callback) { backend.status().toPigeon() }

    override fun getSettings(callback: (Result<EngineSettings>) -> Unit) = call(callback) { backend.settings().toPigeon() }

    override fun setSettings(
        s: EngineSettings,
        callback: (Result<Unit>) -> Unit,
    ) = call(callback) { backend.setSettings(s.toCore(backend.settings())) }

    override fun listAlbums(callback: (Result<List<AlbumInfo>>) -> Unit) = call(callback) { backend.albums().map { it.toPigeon() } }

    override fun listPhoneItems(
        req: PageRequest,
        callback: (Result<PhoneItemPage>) -> Unit,
    ) = call(callback) {
        backend.phoneItems(req.afterKey, req.limit.coerceIn(1, Int.MAX_VALUE.toLong()).toInt()).toPigeon()
    }

    override fun phoneThumbnail(
        localId: String,
        sizePx: Long,
        callback: (Result<ByteArray>) -> Unit,
    ) = call(callback) { backend.thumbnail(localId, sizePx.coerceIn(1, 4096).toInt()) }

    override fun listAttention(callback: (Result<List<AttentionItem>>) -> Unit) =
        call(callback) { backend.attention().map { it.toPigeon() } }

    override fun retry(
        localIds: List<String>,
        callback: (Result<Unit>) -> Unit,
    ) = call(callback) { backend.retry(localIds) }

    override fun listActivity(
        limit: Long,
        callback: (Result<List<ActivityEntry>>) -> Unit,
    ) = call(callback) { backend.activity(limit.coerceIn(1, MAX_ACTIVITY).toInt()).map { it.toPigeon() } }

    override fun freeUpSpace(
        localIds: List<String>?,
        callback: (Result<FreeUpResult>) -> Unit,
    ) = call(callback) { backend.freeUpSpace(localIds).toPigeon() }

    override fun undoSkip(
        sha256: String,
        callback: (Result<Unit>) -> Unit,
    ) = call(callback) {
        if (!backend.undoSkip(sha256)) throw HostException("undo_failed", "The server did not confirm. Try again.")
    }

    override fun saveToGallery(
        assetId: String,
        filename: String,
        mime: String,
        callback: (Result<String>) -> Unit,
    ) = call(callback) { backend.saveToGallery(assetId, filename, mime) }

    override fun discoverServers(
        timeoutMs: Long,
        callback: (Result<List<String>>) -> Unit,
    ) = call(callback) { backend.discover(timeoutMs.coerceIn(0, MAX_DISCOVERY_MS)) }

    companion object {
        private val MAIN by lazy { Handler(Looper.getMainLooper()) }
        private const val MAX_ACTIVITY = 1000L
        private const val MAX_DISCOVERY_MS = 30_000L

        /** Transport kinds that mean "the server could not be reached" to the pairing UI. */
        private val UNREACHABLE = setOf("offline", "timeout", "reset")

        /**
         * Maps a failure to the code Flutter shows copy for:
         * - pairing: `tls` → `pin_mismatch`; transport kinds → `unreachable`;
         *   server problem codes (`pairing_code_invalid`, `rate_limited`, …) and
         *   pair-URI errors pass through;
         * - auth: `needs_repair`, `client_too_old` or `unreachable`;
         * - server answers: the problem code, else `http_<status>`;
         * - other I/O: `unreachable`; anything else `internal`.
         */
        fun errorFor(e: Throwable): FlutterError =
            when (e) {
                is FlutterError -> e
                is HostException -> FlutterError(e.code, e.message)
                is PairException -> {
                    val code =
                        when (e.code) {
                            "tls" -> "pin_mismatch"
                            in UNREACHABLE -> "unreachable"
                            else -> e.code
                        }
                    FlutterError(code, e.message)
                }
                is AuthException ->
                    when (e.outcome) {
                        is RefreshOutcome.NeedsRepair -> FlutterError("needs_repair", "Pair this phone again")
                        is RefreshOutcome.ClientTooOld -> FlutterError("client_too_old", "Update the app")
                        else -> FlutterError("unreachable", e.message)
                    }
                is ServerException -> {
                    val raw = e.raw
                    val code = raw.problem()?.code ?: raw.transport?.let { if (it in UNREACHABLE) "unreachable" else it }
                    FlutterError(code ?: "http_${raw.status}", e.message)
                }
                is IOException -> FlutterError("unreachable", e.message)
                is IllegalArgumentException -> FlutterError("invalid_request", e.message)
                else -> FlutterError("internal", e.toString())
            }
    }
}
