package io.github.prithvirajg.pictunnel.engine.store

import androidx.room.ColumnInfo
import androidx.room.Entity
import androidx.room.Index
import androidx.room.PrimaryKey
import io.github.prithvirajg.pictunnel.engine.model.ItemState

/** One local media item and its backup progress (M§4.1). Every change is persisted before its network call (R1). */
@Entity(
    tableName = "items",
    indices = [
        Index(value = ["state"]),
        Index(value = ["takenAtMs", "localId"]),
        Index(value = ["sha256"]),
    ],
)
data class ItemEntity(
    @PrimaryKey val localId: String,
    val sha256: String?,
    val size: Long,
    val modifiedAtMs: Long,
    val takenAtMs: Long,
    val mime: String,
    val kind: String,
    val pairRole: String,
    val pairLocalId: String?,
    val stackKey: String?,
    val state: ItemState,
    val attempts: Int,
    val nextAttemptAtMs: Long?,
    val uploadId: String?,
    val uploadUrl: String?,
    val uploadOffset: Long?,
    val assetId: String?,
    val lastError: String?,
    val filename: String,
)

/**
 * R3 hash cache, keyed by `(localId, modifiedAt, size)`: one row per item; a
 * lookup with a different fingerprint misses and forces a re-hash.
 */
@Entity(tableName = "hash_cache")
data class HashCacheEntity(
    @PrimaryKey val localId: String,
    val modifiedAtMs: Long,
    val size: Long,
    val sha256: String,
)

/** Incremental scan cursor per MediaStore volume (M§4.2): generation plus volume version. */
@Entity(tableName = "scan_state")
data class ScanStateEntity(
    @PrimaryKey val volume: String,
    val generation: Long,
    val volumeVersion: String?,
)

/** The activity log shown in the app; kept as a bounded ring (trimmed by the controller). */
@Entity(tableName = "activity", indices = [Index(value = ["atMs"])])
data class ActivityEntity(
    @PrimaryKey(autoGenerate = true) val id: Long = 0,
    val atMs: Long,
    val kind: String,
    val localId: String?,
    val message: String,
)

/** Engine settings as string key/value pairs. */
@Entity(tableName = "settings")
data class SettingEntity(
    @PrimaryKey val key: String,
    val value: String,
)

/** One row of the per-state count query. */
data class StateCount(
    val state: ItemState,
    @ColumnInfo(name = "count") val count: Int,
)

/** Item counts by state. */
data class StateCounts(
    val byState: Map<ItemState, Int>,
) {
    val total: Int get() = byState.values.sum()

    operator fun get(state: ItemState): Int = byState[state] ?: 0
}
