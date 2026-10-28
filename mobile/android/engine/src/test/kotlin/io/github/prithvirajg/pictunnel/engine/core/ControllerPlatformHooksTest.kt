package io.github.prithvirajg.pictunnel.engine.core

import android.content.Context
import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import io.github.prithvirajg.pictunnel.engine.model.ItemKind
import io.github.prithvirajg.pictunnel.engine.model.ItemState
import io.github.prithvirajg.pictunnel.engine.model.PairRole
import io.github.prithvirajg.pictunnel.engine.model.PauseReason
import io.github.prithvirajg.pictunnel.engine.net.AuthManager
import io.github.prithvirajg.pictunnel.engine.net.CLIENT
import io.github.prithvirajg.pictunnel.engine.net.CheckItem
import io.github.prithvirajg.pictunnel.engine.net.Endpoints
import io.github.prithvirajg.pictunnel.engine.net.FakeStore
import io.github.prithvirajg.pictunnel.engine.net.ServerClient
import io.github.prithvirajg.pictunnel.engine.net.base
import io.github.prithvirajg.pictunnel.engine.net.credsFor
import io.github.prithvirajg.pictunnel.engine.net.json
import io.github.prithvirajg.pictunnel.engine.net.tokens
import io.github.prithvirajg.pictunnel.engine.platform.ContentMediaSource
import io.github.prithvirajg.pictunnel.engine.platform.FakeMediaProvider
import io.github.prithvirajg.pictunnel.engine.platform.FakeVolumes
import io.github.prithvirajg.pictunnel.engine.platform.MediaStoreScanner
import io.github.prithvirajg.pictunnel.engine.store.EngineDb
import io.github.prithvirajg.pictunnel.engine.store.ItemEntity
import kotlinx.coroutines.runBlocking
import mockwebserver3.Dispatcher
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import mockwebserver3.RecordedRequest
import okhttp3.OkHttpClient
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/** The controller hooks the Android platform layer (Task 9) relies on. */
@RunWith(RobolectricTestRunner::class)
class ControllerPlatformHooksTest {
    private val context: Context get() = ApplicationProvider.getApplicationContext()
    private lateinit var db: EngineDb
    private lateinit var server: MockWebServer
    private lateinit var provider: FakeMediaProvider
    private val clock = FakeClock()
    private var access = MediaAccess.Full

    @Before fun setUp() {
        provider = FakeMediaProvider.install()
        server = MockWebServer()
        server.dispatcher =
            object : Dispatcher() {
                override fun dispatch(request: RecordedRequest): MockResponse =
                    if (request.url.encodedPath == "/api/v1/auth/refresh") {
                        json(200, tokens(1))
                    } else {
                        json(200, """{"results":[]}""")
                    }
            }
        server.start()
        db = Room.inMemoryDatabaseBuilder(context, EngineDb::class.java).allowMainThreadQueries().build()
    }

    @After fun tearDown() {
        db.close()
        server.close()
    }

    /** Endpoint 1 refuses connections, endpoint 2 is the mock server. */
    private fun controller(): Pair<EngineController, ServerClient> {
        val store = FakeStore(credsFor("http://127.0.0.1:1", server.base()))
        val endpoints = Endpoints(store.creds!!.endpoints)
        val auth = AuthManager(store, OkHttpClient(), { clock.monotonicMs() }, CLIENT, endpoints)
        val client = ServerClient(endpoints, auth, OkHttpClient(), CLIENT)
        val settings = SettingsRepo(db.settings())
        val scanner = MediaStoreScanner(context.contentResolver, { settings.get() }, FakeVolumes(provider), { access }, 34)
        return EngineController(
            db,
            scanner,
            ContentMediaSource(context, requireOriginal = { false }),
            client,
            settings,
            clock,
            RecordingEvents(),
        ) to client
    }

    private fun row(
        id: String,
        state: ItemState,
        role: String = PairRole.PRIMARY,
        kind: String = ItemKind.PHOTO,
        pair: String? = null,
    ) = ItemEntity(
        localId = id, sha256 = null, size = 10, modifiedAtMs = 1, takenAtMs = 1, mime = "image/jpeg", kind = kind,
        pairRole = role, pairLocalId = pair, stackKey = null, state = state, attempts = 0, nextAttemptAtMs = null,
        uploadId = null, uploadUrl = null, uploadOffset = null, assetId = null, lastError = null, filename = "$id.jpg",
    )

    @Test fun networkChangeClearsTlsPauseAndResetsEndpoints() =
        runBlocking {
            val (engine, client) = controller()
            client.check(listOf(CheckItem("a".repeat(64), 1, "x")))
            assertTrue(client.activeEndpoint.contains(server.port.toString()))

            val settings = SettingsRepo(db.settings())
            settings.setPause(PauseState(EngineController.UNTRUSTED_PAUSE_REASON, clock.nowMs() + 3_600_000))
            engine.onNetworkChanged()
            assertNull("a captive portal's certificate must not keep backups paused", engine.pauseState())
            assertTrue(client.activeEndpoint.startsWith("http://127.0.0.1:1"))

            // A user pause survives network changes.
            engine.pause(PauseReason.User)
            engine.onNetworkChanged()
            assertEquals(PauseReason.User, engine.pauseState()!!.reason)
        }

    @Test fun statusTotalsExcludeHiddenLiveVideoRows() =
        runBlocking {
            val (engine, _) = controller()
            db.items().upsertAll(
                listOf(
                    row("p", ItemState.BackedUp),
                    row("live", ItemState.BackedUp, kind = ItemKind.LIVE_PHOTO, pair = "live-v"),
                    row("live-v", ItemState.BackedUp, role = PairRole.LIVE_VIDEO, kind = ItemKind.VIDEO, pair = "live"),
                    row("q", ItemState.Queued),
                ),
            )
            val s = engine.status()
            assertEquals(3, s.total)
            assertEquals(2, s.backedUp)
            assertEquals(1, s.queued)
            // Remaining work: one item; bytes count every component still to send.
            assertEquals(RemainingWork(1, 10), engine.remainingWork())
        }

    @Test fun mediaAccessIsExposedForTheBridge() {
        val (engine, _) = controller()
        assertEquals(MediaAccess.Full, engine.mediaAccess())
        access = MediaAccess.Partial
        assertEquals(MediaAccess.Partial, engine.mediaAccess())
        assertEquals(MediaAccess.Partial, runBlocking { engine.status() }.mediaAccess)
        access = MediaAccess.None
        assertEquals(MediaAccess.None, runBlocking { engine.status() }.mediaAccess)
    }

    @Test fun attentionListsFailedAndTombstonedItems() =
        runBlocking {
            val (engine, _) = controller()
            db.items().upsertAll(
                listOf(
                    row("bad", ItemState.NeedsAttention).copy(lastError = "file_too_large", attempts = 10, sha256 = "b".repeat(64)),
                    row("gone", ItemState.Skipped).copy(lastError = "tombstoned", sha256 = "c".repeat(64)),
                    row("gone-v", ItemState.Skipped, role = PairRole.LIVE_VIDEO).copy(sha256 = "d".repeat(64)),
                    row("ok", ItemState.BackedUp),
                ),
            )
            val list = engine.listAttention()
            assertEquals(listOf("bad", "gone"), list.map { it.localId })
            assertNull("failed items offer Retry, not Back up again", list[0].sha256)
            assertEquals("file_too_large", list[0].code)
            assertEquals("c".repeat(64), list[1].sha256)
            assertEquals(EngineController.TOMBSTONED, list[1].code)
            assertEquals("gone.jpg", list[1].filename)
        }

    @Test fun turningVideosOnRescansExistingVideos() =
        runBlocking {
            val (engine, _) = controller()
            engine.setSettings(EngineSettings(includeVideos = false))
            val photo = provider.add(bytes = ByteArray(3))
            val video = provider.add(type = "video", bytes = ByteArray(4), durationMs = 1000)
            assertEquals(1, engine.scanNow())
            assertNull(db.items().get("external_primary:video:$video"))

            // The video is older than the stored cursor, so only a cursor reset finds it.
            engine.setSettings(EngineSettings(includeVideos = true))
            assertTrue(db.scanState().all().isEmpty())
            engine.scanNow()
            assertEquals(ItemState.Discovered, db.items().get("external_primary:video:$video")!!.state)
            assertEquals(ItemState.Discovered, db.items().get("external_primary:image:$photo")!!.state)
        }

    @Test fun scanNowReportsOnlyNewWork() =
        runBlocking {
            val (engine, _) = controller()
            provider.add(bytes = ByteArray(3))
            assertEquals(1, engine.scanNow())
            assertEquals(0, engine.scanNow())
        }
}
