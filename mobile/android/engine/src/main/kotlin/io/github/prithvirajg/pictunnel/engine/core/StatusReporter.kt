package io.github.prithvirajg.pictunnel.engine.core

import io.github.prithvirajg.pictunnel.engine.model.ItemState
import io.github.prithvirajg.pictunnel.engine.store.ItemEntity
import io.github.prithvirajg.pictunnel.engine.store.ItemsDao
import java.util.concurrent.ConcurrentHashMap

/**
 * Builds [BackupStatus] snapshots from the store and the uploads in flight, and
 * pushes them to [EngineEvents] at most every [MIN_INTERVAL_MS] (the bridge
 * relay throttles again to 4 per second, M§3). [publish] with `force` always
 * emits, for the end of a run.
 */
class StatusReporter(
    private val items: ItemsDao,
    private val settings: SettingsRepo,
    private val clock: Clock,
    private val events: EngineEvents,
) {
    private class InFlight(
        val localId: String,
        val filename: String,
        val total: Long,
        val startedMono: Long,
        val startOffset: Long,
    ) {
        @Volatile var sent: Long = startOffset

        @Volatile var touchedMono: Long = startedMono
    }

    private val inFlight = ConcurrentHashMap<String, InFlight>()

    @Volatile private var lastEmitMono: Long? = null

    fun uploadStarted(item: ItemEntity) {
        val off = item.uploadOffset ?: 0
        inFlight[item.localId] = InFlight(item.localId, item.filename, item.size, clock.monotonicMs(), off)
    }

    /** Called as upload bytes leave; [offset] is the absolute file offset reached. */
    fun bytesSent(
        localId: String,
        offset: Long,
    ) {
        val f = inFlight[localId] ?: return
        f.sent = offset
        f.touchedMono = clock.monotonicMs()
    }

    fun uploadEnded(localId: String) {
        inFlight.remove(localId)
    }

    /** The most recently active upload, if any. */
    fun current(): UploadProgress? {
        val f = inFlight.values.maxByOrNull { it.touchedMono } ?: return null
        val elapsed = (clock.monotonicMs() - f.startedMono).coerceAtLeast(1)
        return UploadProgress(f.localId, f.filename, f.sent, f.total, (f.sent - f.startOffset) * 1000.0 / elapsed)
    }

    suspend fun snapshot(): BackupStatus {
        // Totals match the phone index: hidden Live Photo video components are not counted.
        val c = items.primaryCounts()
        val pause = settings.pause()
        return BackupStatus(
            backedUp = c[ItemState.BackedUp] + c[ItemState.Freed],
            total = c.total,
            queued = c[ItemState.Queued] + c[ItemState.Uploading] + c[ItemState.Verifying],
            uploading = current(),
            needsAttention = c[ItemState.NeedsAttention],
            skipped = c[ItemState.Skipped],
            freeableBytes = items.sumSize(ItemState.BackedUp),
            paused = pause != null,
            pauseReason = pause?.reason,
            lastRunAtMs = settings.lastRunAtMs(),
            preparing = c[ItemState.Discovered] + c[ItemState.Hashed],
        )
    }

    suspend fun publish(force: Boolean = false) {
        val now = clock.monotonicMs()
        val last = lastEmitMono
        if (!force && last != null && now - last < MIN_INTERVAL_MS) return
        lastEmitMono = now
        events.status(snapshot())
    }

    companion object {
        const val MIN_INTERVAL_MS = 250L
    }
}
