package io.github.prithvirajg.pictunnel.engine.store

import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import io.github.prithvirajg.pictunnel.engine.model.ItemState
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

@RunWith(RobolectricTestRunner::class)
class ItemsDaoTest {
    private lateinit var db: EngineDb
    private lateinit var dao: ItemsDao

    @Before
    fun open() {
        db =
            Room
                .inMemoryDatabaseBuilder(ApplicationProvider.getApplicationContext(), EngineDb::class.java)
                .allowMainThreadQueries()
                .build()
        dao = db.items()
    }

    @After
    fun close() = db.close()

    private fun item(
        id: String,
        takenAt: Long = 1_000L,
        state: ItemState = ItemState.Discovered,
    ) = ItemEntity(
        localId = id,
        sha256 = null,
        size = 100,
        modifiedAtMs = 10,
        takenAtMs = takenAt,
        mime = "image/jpeg",
        kind = "photo",
        pairRole = "primary",
        pairLocalId = null,
        stackKey = null,
        state = state,
        attempts = 0,
        nextAttemptAtMs = null,
        uploadId = null,
        uploadUrl = null,
        uploadOffset = null,
        assetId = null,
        lastError = null,
        filename = "$id.jpg",
    )

    @Test
    fun upsertIsIdempotent() =
        runBlocking {
            dao.upsert(item("a"))
            dao.upsert(item("a"))
            assertEquals(1, dao.counts().total)

            dao.upsert(item("a", state = ItemState.Hashed).copy(sha256 = "ff"))
            val got = dao.get("a")!!
            assertEquals(ItemState.Hashed, got.state)
            assertEquals("ff", got.sha256)
            assertEquals(1, dao.counts().total)
            assertNull(dao.get("missing"))
        }

    @Test
    fun pagingIsKeysetNewestFirst() =
        runBlocking {
            // Ties on takenAt are broken by localId, descending.
            val items =
                listOf(
                    item("a", takenAt = 300),
                    item("b", takenAt = 200),
                    item("c", takenAt = 200),
                    item("d", takenAt = 200),
                    item("e", takenAt = 100),
                )
            dao.upsertAll(items.shuffled())

            val seen = mutableListOf<String>()
            var afterTakenAt: Long? = null
            var afterLocalId: String? = null
            while (true) {
                val page = dao.page(afterTakenAt, afterLocalId, 2)
                if (page.isEmpty()) break
                assert(page.size <= 2)
                seen += page.map { it.localId }
                afterTakenAt = page.last().takenAtMs
                afterLocalId = page.last().localId
            }
            assertEquals(listOf("a", "d", "c", "b", "e"), seen)
        }

    @Test
    fun countsGroupByState() =
        runBlocking {
            dao.upsertAll(
                listOf(
                    item("a", state = ItemState.BackedUp),
                    item("b", state = ItemState.BackedUp),
                    item("c", state = ItemState.Queued),
                    item("d", state = ItemState.NeedsAttention),
                ),
            )
            val counts = dao.counts()
            assertEquals(4, counts.total)
            assertEquals(2, counts[ItemState.BackedUp])
            assertEquals(1, counts[ItemState.Queued])
            assertEquals(1, counts[ItemState.NeedsAttention])
            assertEquals(0, counts[ItemState.Skipped])
        }

    @Test
    fun byStateAndSetState() =
        runBlocking {
            dao.upsertAll(
                listOf(
                    item("a", takenAt = 1, state = ItemState.Queued),
                    item("b", takenAt = 2, state = ItemState.Hashed),
                    item("c", takenAt = 3, state = ItemState.BackedUp),
                ),
            )
            assertEquals(
                listOf("b", "a"),
                dao.byState(listOf(ItemState.Queued, ItemState.Hashed), 10).map { it.localId },
            )
            assertEquals(1, dao.byState(listOf(ItemState.Queued, ItemState.Hashed), 1).size)

            assertEquals(1, dao.setState("a", ItemState.Uploading, attempts = 3, nextAttemptAtMs = 99, lastError = "x"))
            val a = dao.get("a")!!
            assertEquals(ItemState.Uploading, a.state)
            assertEquals(3, a.attempts)
            assertEquals(99L, a.nextAttemptAtMs)
            assertEquals("x", a.lastError)
            assertEquals(0, dao.setState("missing", ItemState.Uploading, 0, null, null))
        }

    @Test
    fun hashCacheKeyedByFingerprint() =
        runBlocking {
            val cache = db.hashCache()
            cache.put(HashCacheEntity(localId = "a", modifiedAtMs = 10, size = 100, sha256 = "aa"))
            assertEquals("aa", cache.lookup("a", 10, 100))
            // R3: any difference in modifiedAt or size forces a re-hash.
            assertNull(cache.lookup("a", 11, 100))
            assertNull(cache.lookup("a", 10, 101))
        }
}
