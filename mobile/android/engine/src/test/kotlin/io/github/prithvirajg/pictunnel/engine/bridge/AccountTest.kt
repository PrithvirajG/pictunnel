package io.github.prithvirajg.pictunnel.engine.bridge

import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import io.github.prithvirajg.pictunnel.engine.core.PauseState
import io.github.prithvirajg.pictunnel.engine.core.RunBudget
import io.github.prithvirajg.pictunnel.engine.core.SettingsRepo
import io.github.prithvirajg.pictunnel.engine.model.ItemKind
import io.github.prithvirajg.pictunnel.engine.model.ItemState
import io.github.prithvirajg.pictunnel.engine.model.PairRole
import io.github.prithvirajg.pictunnel.engine.model.PauseReason
import io.github.prithvirajg.pictunnel.engine.sched.FakeEngine
import io.github.prithvirajg.pictunnel.engine.sched.RunCoordinator
import io.github.prithvirajg.pictunnel.engine.store.ActivityEntity
import io.github.prithvirajg.pictunnel.engine.store.EngineDb
import io.github.prithvirajg.pictunnel.engine.store.HashCacheEntity
import io.github.prithvirajg.pictunnel.engine.store.ItemEntity
import io.github.prithvirajg.pictunnel.engine.store.ScanStateEntity
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/** Pairing and unpairing state (review fix round 1): a server switch and unpair clear the index, preempting runs. */
@RunWith(RobolectricTestRunner::class)
class AccountTest {
    private lateinit var db: EngineDb
    private lateinit var settings: SettingsRepo
    private val runs = RunCoordinator()
    private lateinit var account: Account

    @Before fun setUp() {
        db = Room.inMemoryDatabaseBuilder(ApplicationProvider.getApplicationContext(), EngineDb::class.java).allowMainThreadQueries().build()
        settings = SettingsRepo(db.settings())
        account = Account(db, settings, runs)
    }

    @After fun tearDown() = db.close()

    private suspend fun seed() {
        db.items().upsert(
            ItemEntity(
                localId = "external_primary:image:1", sha256 = "ab".repeat(32), size = 10, modifiedAtMs = 1, takenAtMs = 1,
                mime = "image/jpeg", kind = ItemKind.PHOTO, pairRole = PairRole.PRIMARY, pairLocalId = null, stackKey = null,
                state = ItemState.BackedUp, attempts = 0, nextAttemptAtMs = null, uploadId = null, uploadUrl = null,
                uploadOffset = null, assetId = "asset-old", lastError = null, filename = "IMG_1.JPG",
                width = null, height = null, durationMs = null,
            ),
        )
        db.scanState().put(ScanStateEntity("external_primary", 42, "v1"))
        db.activity().add(ActivityEntity(atMs = 1, kind = "upload", localId = null, message = "Uploaded"))
        db.hashCache().put(HashCacheEntity("external_primary:image:1", 1, 10, "ab".repeat(32)))
        settings.setPause(PauseState(PauseReason.Quota, null))
    }

    private suspend fun indexIsEmpty() {
        assertTrue(db.items().allIds().isEmpty())
        assertTrue(db.scanState().all().isEmpty())
        assertTrue(db.activity().latest(10).isEmpty())
        assertNull(settings.pause())
    }

    @Test fun pairingADifferentServerClearsTheOldIndex() =
        runBlocking {
            settings.setServer("srv-old", "Old NAS")
            seed()
            // A backup run is in progress for the old server: the switch preempts it.
            val engine = FakeEngine().apply { onRun = { awaitCancellation() } }
            val run = async(Dispatchers.Default) { runs.run(engine, RunBudget()) }
            engine.runStarted.await()

            val name = account.adoptServer("srv-new") { "New NAS" }

            assertNull("the running backup was stopped first", run.await())
            assertEquals("New NAS", name)
            assertEquals("srv-new", settings.pairedServerId())
            assertEquals("New NAS", settings.serverName())
            indexIsEmpty()
            assertEquals("cached hashes stay", "ab".repeat(32), db.hashCache().lookup("external_primary:image:1", 1, 10))
        }

    @Test fun pairingTheSameServerAgainKeepsTheIndex() =
        runBlocking {
            settings.setServer("srv", "Home")
            seed()
            assertEquals("Home", account.adoptServer("srv") { throw java.io.IOException("offline") })
            assertEquals(listOf("external_primary:image:1"), db.items().allIds())
        }

    @Test fun theServerIdIsRecordedBeforeTheNameLookup() =
        runBlocking {
            var seenDuringLookup: String? = null
            val name = account.adoptServer("srv") { seenDuringLookup = settings.pairedServerId(); null }
            assertEquals("srv", seenDuringLookup)
            assertEquals(Account.DEFAULT_NAME, name)
        }

    @Test fun forgetClearsTheIndexAndServerButKeepsHashes() =
        runBlocking {
            settings.setServer("srv", "Home")
            settings.setLastRunAtMs(5)
            seed()
            account.forget()
            indexIsEmpty()
            assertNull(settings.pairedServerId())
            assertNull(settings.serverName())
            assertNull(settings.lastRunAtMs())
            assertEquals("ab".repeat(32), db.hashCache().lookup("external_primary:image:1", 1, 10))
        }
}
