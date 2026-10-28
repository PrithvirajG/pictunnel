package io.github.prithvirajg.pictunnel.engine.bridge

import io.github.prithvirajg.pictunnel.engine.core.AttentionItem as CoreAttention
import io.github.prithvirajg.pictunnel.engine.core.BackupStatus as CoreStatus
import io.github.prithvirajg.pictunnel.engine.core.EngineSettings as CoreSettings
import io.github.prithvirajg.pictunnel.engine.core.FreeUpResult as CoreFreeUp
import io.github.prithvirajg.pictunnel.engine.core.PhoneItemPage as CorePage
import io.github.prithvirajg.pictunnel.engine.model.PauseReason as CorePause
import io.github.prithvirajg.pictunnel.engine.pairing.PairResult as CorePairResult
import io.github.prithvirajg.pictunnel.engine.pairing.ServerFingerprint
import io.github.prithvirajg.pictunnel.engine.platform.Album
import io.github.prithvirajg.pictunnel.engine.store.ActivityEntity

/** A completed pairing plus the server's display name. */
data class Paired(
    val result: CorePairResult,
    val serverName: String,
)

/** What `serverInfo` reports about the paired server. */
data class Connection(
    val serverId: String,
    val name: String,
    val activeEndpoint: String,
    val onLan: Boolean,
    val fp16: String,
)

/**
 * A failure with a code the Flutter side understands (it becomes the
 * `PlatformException.code`), for example `not_paired` or `undo_failed`.
 */
class HostException(
    val code: String,
    message: String? = null,
) : Exception(message ?: code)

/**
 * Everything [EngineHost] delegates to, in engine terms: the controller, the
 * scheduler and the platform adapters. [AndroidHostBackend] is the real one;
 * tests fake it. Methods throw [HostException],
 * [io.github.prithvirajg.pictunnel.engine.pairing.PairException] or any other
 * exception; [EngineHost] maps them to Flutter error codes.
 */
interface HostBackend {
    suspend fun pairQr(
        qrUri: String,
        deviceName: String,
    ): Paired

    suspend fun pairManual(
        serverUrl: String,
        code: String,
        pin: String,
        deviceName: String,
    ): Paired

    suspend fun trustOnFirstUse(serverUrl: String): ServerFingerprint

    suspend fun unpair()

    suspend fun accessToken(): String

    suspend fun connection(): Connection?

    suspend fun start()

    suspend fun pause(reason: CorePause)

    suspend fun runNow()

    suspend fun status(): CoreStatus

    suspend fun settings(): CoreSettings

    suspend fun setSettings(s: CoreSettings)

    suspend fun albums(): List<Album>

    suspend fun phoneItems(
        afterKey: String?,
        limit: Int,
    ): CorePage

    suspend fun thumbnail(
        localId: String,
        sizePx: Int,
    ): ByteArray

    suspend fun attention(): List<CoreAttention>

    suspend fun retry(localIds: List<String>)

    suspend fun activity(limit: Int): List<ActivityEntity>

    suspend fun freeUpSpace(localIds: List<String>?): CoreFreeUp

    /** False when the server did not confirm removing the tombstone. */
    suspend fun undoSkip(sha256: String): Boolean

    suspend fun saveToGallery(
        assetId: String,
        filename: String,
        mime: String,
    ): String

    /** Discovered servers' https URLs after [timeoutMs]. */
    suspend fun discover(timeoutMs: Long): List<String>
}
