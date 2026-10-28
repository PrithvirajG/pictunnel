package io.github.prithvirajg.pictunnel.engine.bridge

import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import io.github.prithvirajg.pictunnel.engine.core.EngineEvents
import io.github.prithvirajg.pictunnel.engine.store.ItemEntity
import io.github.prithvirajg.pictunnel.engine.core.BackupStatus as CoreStatus

/**
 * Engine events to Flutter's [EngineEventsApi] (M§3), at most [MAX_PER_SECOND]
 * deliveries a second. Status updates coalesce to the latest; item changes
 * coalesce per local id; both go out together, on the main thread, at most
 * every [minIntervalMs]. `needsRepair` is never delayed.
 *
 * The engine outlives the UI (workers run without an activity), so the relay
 * is attached to a Flutter engine's messenger while one exists ([attach]) and
 * drops events otherwise: the app reads fresh state when it comes back.
 */
class EventsRelay(
    private val handler: Handler = Handler(Looper.getMainLooper()),
    private val minIntervalMs: Long = 1000L / MAX_PER_SECOND,
    private val now: () -> Long = SystemClock::uptimeMillis,
    /** Also run on needsRepair (the credentials are gone): the app drops its engine session. */
    private val onNeedsRepair: () -> Unit = {},
) : EngineEvents {
    private val lock = Any()

    @Volatile private var api: EngineEventsApi? = null
    private var pendingStatus: CoreStatus? = null
    private val pendingItems = LinkedHashMap<String, ItemEntity>()
    private var lastFlush: Long? = null
    private var scheduled = false

    fun attach(api: EngineEventsApi) {
        this.api = api
    }

    fun detach() {
        api = null
        synchronized(lock) {
            pendingStatus = null
            pendingItems.clear()
        }
    }

    override fun status(s: CoreStatus) {
        synchronized(lock) { pendingStatus = s }
        schedule()
    }

    override fun itemChanged(i: ItemEntity) {
        synchronized(lock) {
            pendingItems.remove(i.localId)
            pendingItems[i.localId] = i
        }
        schedule()
    }

    override fun needsRepair() {
        onNeedsRepair()
        handler.post { api?.onNeedsRepair { } }
    }

    private fun schedule() {
        val delay: Long
        synchronized(lock) {
            if (scheduled) return
            scheduled = true
            val last = lastFlush
            delay = if (last == null) 0 else (last + minIntervalMs - now()).coerceAtLeast(0)
        }
        handler.postDelayed(::flush, delay)
    }

    private fun flush() {
        val status: CoreStatus?
        val items: List<ItemEntity>
        synchronized(lock) {
            scheduled = false
            lastFlush = now()
            status = pendingStatus
            pendingStatus = null
            items = pendingItems.values.toList()
            pendingItems.clear()
        }
        val target = api ?: return
        for (i in items) target.onItemChanged(i.toPigeon()) { }
        if (status != null) target.onStatus(status.toPigeon()) { }
    }

    companion object {
        const val MAX_PER_SECOND = 4
    }
}
