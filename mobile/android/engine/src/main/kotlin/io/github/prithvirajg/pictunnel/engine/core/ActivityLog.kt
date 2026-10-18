package io.github.prithvirajg.pictunnel.engine.core

import io.github.prithvirajg.pictunnel.engine.store.ActivityDao
import io.github.prithvirajg.pictunnel.engine.store.ActivityEntity

/** The activity log shown in the app (M§3 `listActivity`): a ring buffer of the newest [CAPACITY] entries in Room. */
class ActivityLog(
    private val dao: ActivityDao,
    private val clock: Clock,
) {
    suspend fun add(
        kind: String,
        message: String,
        localId: String? = null,
    ) {
        dao.add(ActivityEntity(atMs = clock.nowMs(), kind = kind, localId = localId, message = message))
        dao.trim(CAPACITY)
    }

    suspend fun latest(limit: Int): List<ActivityEntity> = dao.latest(limit.coerceIn(0, CAPACITY))

    companion object {
        const val CAPACITY = 1000

        const val BACKED_UP = "backed_up"
        const val SKIPPED = "skipped"
        const val NEEDS_ATTENTION = "needs_attention"
        const val PAUSED = "paused"
        const val FREED = "freed"
        const val ERROR = "error"
        const val INFO = "info"
    }
}
