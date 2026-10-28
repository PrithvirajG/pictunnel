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

    /** Per-state counts of primary items only, matching the phone index (a Live Photo's video is hidden). */
    @Query("SELECT state, COUNT(*) AS count FROM items WHERE pairRole = 'primary' GROUP BY state")
    suspend fun countPrimaryRows(): List<StateCount>

    suspend fun primaryCounts(): StateCounts = StateCounts(countPrimaryRows().associate { it.state to it.count })

    /** Primary items in [states] and the bytes of every row (all components) in them. */
    @Query(
        """
        SELECT COALESCE(SUM(CASE WHEN pairRole = 'primary' THEN 1 ELSE 0 END), 0) AS count,
               COALESCE(SUM(size), 0) AS bytes
        FROM items WHERE state IN (:states)
        """,
    )
    suspend fun remaining(states: List<ItemState>): CountAndBytes

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

    /**
     * Items in any of [states] that are due at [nowMs], newest first, strictly
     * after the keyset `(afterTakenAt, afterLocalId)` (nulls for the first page).
     * A backoff later than [latestValidMs] cannot have been set by this clock
     * (no wait exceeds the 15 min cap), so the clock jumped back and the row is
     * due now (R10).
     */
    @Query(
        """
        SELECT * FROM items
        WHERE state IN (:states)
          AND (nextAttemptAtMs IS NULL OR nextAttemptAtMs <= :nowMs OR nextAttemptAtMs > :latestValidMs)
          AND (:afterTakenAt IS NULL
            OR takenAtMs < :afterTakenAt
            OR (takenAtMs = :afterTakenAt AND localId < :afterLocalId))
        ORDER BY takenAtMs DESC, localId DESC
        LIMIT :limit
        """,
    )
    suspend fun due(
        states: List<ItemState>,
        nowMs: Long,
        latestValidMs: Long,
        afterTakenAt: Long?,
        afterLocalId: String?,
        limit: Int,
    ): List<ItemEntity>

    /** The earliest pending backoff among [states], or null when nothing waits. */
    @Query("SELECT MIN(nextAttemptAtMs) FROM items WHERE state IN (:states) AND nextAttemptAtMs > :nowMs")
    suspend fun nextAttemptAfter(
        states: List<ItemState>,
        nowMs: Long,
    ): Long?

    @Query("SELECT COALESCE(SUM(size), 0) FROM items WHERE state = :state")
    suspend fun sumSize(state: ItemState): Long

    /** Forgets every item (pairing with a different server); the hash cache is kept. */
    @Query("DELETE FROM items")
    suspend fun clear(): Int

    @Query("SELECT localId FROM items")
    suspend fun allIds(): List<String>

    @Query("SELECT * FROM items WHERE sha256 = :sha256")
    suspend fun bySha(sha256: String): List<ItemEntity>

    /**
     * The phone timeline (M§3 `listPhoneItems`): primary items only (a Live
     * Photo's paired video is a hidden component), newest first by
     * `(takenAtMs, localId)`, strictly after the given key.
     */
    @Query(
        """
        SELECT * FROM items
        WHERE pairRole = 'primary'
          AND (:afterTakenAt IS NULL
            OR takenAtMs < :afterTakenAt
            OR (takenAtMs = :afterTakenAt AND localId < :afterLocalId))
        ORDER BY takenAtMs DESC, localId DESC
        LIMIT :limit
        """,
    )
    suspend fun phonePage(
        afterTakenAt: Long?,
        afterLocalId: String?,
        limit: Int,
    ): List<ItemEntity>
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

    @Query("SELECT * FROM scan_state")
    suspend fun all(): List<ScanStateEntity>

    /** Forgets every cursor: the next scan is a full rescan (volume change or scope-changing setting). */
    @Query("DELETE FROM scan_state")
    suspend fun clear(): Int
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

    @Query("DELETE FROM settings WHERE key = :key")
    suspend fun remove(key: String): Int

    /** One transaction: related keys change together. */
    @Upsert
    suspend fun putAll(settings: List<SettingEntity>)

    @Query("DELETE FROM settings WHERE key IN (:keys)")
    suspend fun removeAll(keys: List<String>): Int
}
