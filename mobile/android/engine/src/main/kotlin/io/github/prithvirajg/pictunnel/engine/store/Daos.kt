package io.github.prithvirajg.pictunnel.engine.store

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.Query
import androidx.room.Upsert
import io.github.prithvirajg.pictunnel.engine.model.ItemState

@Dao
interface ItemsDao {
    @Upsert
    suspend fun upsert(item: ItemEntity)

    @Upsert
    suspend fun upsertAll(items: List<ItemEntity>)

    @Query("SELECT * FROM items WHERE localId = :localId")
    suspend fun get(localId: String): ItemEntity?

    /** Items in any of [states], newest first. */
    @Query("SELECT * FROM items WHERE state IN (:states) ORDER BY takenAtMs DESC, localId DESC LIMIT :limit")
    suspend fun byState(
        states: List<ItemState>,
        limit: Int,
    ): List<ItemEntity>

    /**
     * Keyset page, newest first, ordered by `(takenAtMs, localId)` descending.
     * Pass nulls for the first page, then the last row's values.
     */
    @Query(
        """
        SELECT * FROM items
        WHERE :afterTakenAt IS NULL
           OR takenAtMs < :afterTakenAt
           OR (takenAtMs = :afterTakenAt AND localId < :afterLocalId)
        ORDER BY takenAtMs DESC, localId DESC
        LIMIT :limit
        """,
    )
    suspend fun page(
        afterTakenAt: Long?,
        afterLocalId: String?,
        limit: Int,
    ): List<ItemEntity>

    @Query("SELECT state, COUNT(*) AS count FROM items GROUP BY state")
    suspend fun countRows(): List<StateCount>

    suspend fun counts(): StateCounts = StateCounts(countRows().associate { it.state to it.count })

    /** Returns the number of rows changed (0 if the item is unknown). */
    @Query(
        """
        UPDATE items SET state = :state, attempts = :attempts,
            nextAttemptAtMs = :nextAttemptAtMs, lastError = :lastError
        WHERE localId = :localId
        """,
    )
    suspend fun setState(
        localId: String,
        state: ItemState,
        attempts: Int,
        nextAttemptAtMs: Long?,
        lastError: String?,
    ): Int

    @Query("DELETE FROM items WHERE localId IN (:localIds)")
    suspend fun delete(localIds: List<String>): Int
}

@Dao
interface HashCacheDao {
    @Upsert
    suspend fun put(entry: HashCacheEntity)

    /** R3: a hit only when the fingerprint is unchanged. */
    @Query("SELECT sha256 FROM hash_cache WHERE localId = :localId AND modifiedAtMs = :modifiedAtMs AND size = :size")
    suspend fun lookup(
        localId: String,
        modifiedAtMs: Long,
        size: Long,
    ): String?

    @Query("DELETE FROM hash_cache WHERE localId IN (:localIds)")
    suspend fun delete(localIds: List<String>): Int
}

@Dao
interface ScanStateDao {
    @Upsert
    suspend fun put(state: ScanStateEntity)

    @Query("SELECT * FROM scan_state WHERE volume = :volume")
    suspend fun get(volume: String): ScanStateEntity?
}

@Dao
interface ActivityDao {
    @Insert
    suspend fun add(entry: ActivityEntity): Long

    @Query("SELECT * FROM activity ORDER BY id DESC LIMIT :limit")
    suspend fun latest(limit: Int): List<ActivityEntity>

    /** Keeps only the newest [keep] rows. */
    @Query("DELETE FROM activity WHERE id NOT IN (SELECT id FROM activity ORDER BY id DESC LIMIT :keep)")
    suspend fun trim(keep: Int): Int
}

@Dao
interface SettingsDao {
    @Upsert
    suspend fun put(setting: SettingEntity)

    @Query("SELECT value FROM settings WHERE key = :key")
    suspend fun get(key: String): String?

    @Query("SELECT * FROM settings")
    suspend fun all(): List<SettingEntity>
}
