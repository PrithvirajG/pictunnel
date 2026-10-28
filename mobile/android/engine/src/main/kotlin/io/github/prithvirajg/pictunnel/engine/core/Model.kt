package io.github.prithvirajg.pictunnel.engine.core

import io.github.prithvirajg.pictunnel.engine.model.PauseReason
import io.github.prithvirajg.pictunnel.engine.store.ItemEntity

/** Wall and monotonic time. Correctness never depends on the wall clock (R10); it only schedules backoff. */
interface Clock {
    fun nowMs(): Long

    fun monotonicMs(): Long

    companion object {
        val System: Clock =
            object : Clock {
                override fun nowMs(): Long = java.lang.System.currentTimeMillis()

                override fun monotonicMs(): Long = java.lang.System.nanoTime() / 1_000_000
            }
    }
}

/** Callbacks to the app (the Pigeon `EngineEventsApi`; the relay throttles them, M§3). */
interface EngineEvents {
    fun status(s: BackupStatus)

    fun itemChanged(i: ItemEntity)

    /** Credentials were wiped (refresh token reused or device revoked): send the UI to pairing. */
    fun needsRepair()
}

/**
 * Deletes local originals through the OS confirmation dialog (M§4.5) and
 * returns the ids the user actually confirmed. A cancelled dialog returns an
 * empty set.
 */
fun interface Deleter {
    suspend fun delete(localIds: List<String>): Set<String>
}

/** Limits for one run; null means unlimited. [maxUploads] counts upload items started. */
data class RunBudget(
    val maxDurationMs: Long? = null,
    val maxUploads: Int? = null,
)

/** Why a run ended. */
enum class StopReason {
    /** Nothing left that is due. */
    Idle,

    /** The [RunBudget] ran out with work left. */
    Budget,

    /** No endpoint is reachable; nothing counted as an attempt (R5). */
    Offline,

    /** The run is paused (by the user or by the server: storage, quota, client too old). */
    Paused,

    /** TLS failed on every endpoint, most likely a changed certificate: pair again. */
    ServerUntrusted,

    /** The credentials are gone (reuse or revocation): pair again. */
    NeedsRepair,
}

data class RunReport(
    val scanned: Int,
    val hashed: Int,
    val checked: Int,
    val backedUp: Int,
    val skipped: Int,
    val needsAttention: Int,
    val stop: StopReason,
    /** The earliest pending backoff, for scheduling the next run; null when nothing waits. */
    val nextAttemptAtMs: Long?,
)

/** The upload in flight that the status shows. */
data class UploadProgress(
    val localId: String,
    val filename: String,
    val sentBytes: Long,
    val totalBytes: Long,
    val bytesPerSecond: Double,
)

/** Mirrors the Pigeon `BackupStatus`. */
data class BackupStatus(
    val backedUp: Int,
    val total: Int,
    val queued: Int,
    val uploading: UploadProgress?,
    val needsAttention: Int,
    val skipped: Int,
    val freeableBytes: Long,
    val paused: Boolean,
    val pauseReason: PauseReason?,
    val lastRunAtMs: Long?,
    val preparing: Int,
    val mediaAccess: MediaAccess = MediaAccess.Full,
)

data class SkippedFree(
    val localId: String,
    val reason: String,
)

data class FreeUpResult(
    val freedCount: Int,
    val freedBytes: Long,
    val skipped: List<SkippedFree>,
)

data class PhoneItemPage(
    val items: List<ItemEntity>,
    /** Exclusive key `"<takenAtMs>|<localId>"` for the next page; null on the last page. */
    val nextKey: String?,
)

data class AttentionItem(
    val localId: String,
    val filename: String,
    val code: String,
    val message: String,
    val attempts: Int,
    /** Set only for skipped (tombstoned) items: the content to "Back up again" with `undoSkip`. */
    val sha256: String? = null,
)

/**
 * Engine tuning. [chunkBytes] overrides the server's `recommended_chunk_bytes`
 * (tests only); [checkBatchSize] is at most 1000 (R6); [random] drives backoff
 * jitter; [maxPasses] bounds the hash → check → upload passes of one run.
 */
data class EngineConfig(
    val chunkBytes: Long? = null,
    val checkBatchSize: Int = 1000,
    val random: java.util.Random = java.util.Random(),
    val maxPasses: Int = 20,
) {
    init {
        require(checkBatchSize in 1..1000) { "check batches hold 1..1000 items (R6)" }
    }
}
