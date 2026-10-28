package io.github.prithvirajg.pictunnel.engine.platform

import android.content.Context
import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import io.github.prithvirajg.pictunnel.engine.core.Deleter
import io.github.prithvirajg.pictunnel.engine.core.EngineConfig
import io.github.prithvirajg.pictunnel.engine.core.EngineController
import io.github.prithvirajg.pictunnel.engine.core.FakeClock
import io.github.prithvirajg.pictunnel.engine.core.MediaAccess
import io.github.prithvirajg.pictunnel.engine.core.RecordingEvents
import io.github.prithvirajg.pictunnel.engine.core.RunBudget
import io.github.prithvirajg.pictunnel.engine.core.SettingsRepo
import io.github.prithvirajg.pictunnel.engine.core.metaOf
import io.github.prithvirajg.pictunnel.engine.core.sha
import io.github.prithvirajg.pictunnel.engine.model.ItemState
import io.github.prithvirajg.pictunnel.engine.net.AuthManager
import io.github.prithvirajg.pictunnel.engine.net.CLIENT
import io.github.prithvirajg.pictunnel.engine.net.Endpoints
import io.github.prithvirajg.pictunnel.engine.net.FakeStore
import io.github.prithvirajg.pictunnel.engine.net.ServerClient
import io.github.prithvirajg.pictunnel.engine.net.base
import io.github.prithvirajg.pictunnel.engine.net.credsFor
import io.github.prithvirajg.pictunnel.engine.net.json
import io.github.prithvirajg.pictunnel.engine.net.tokens
import io.github.prithvirajg.pictunnel.engine.store.EngineDb
import kotlinx.coroutines.runBlocking
import mockwebserver3.Dispatcher
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import mockwebserver3.RecordedRequest
import okhttp3.OkHttpClient
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import java.util.Collections

/**
 * Review Focus 2: a photo edited in place on the phone (same MediaStore id,
 * new bytes) is never freed on the strength of the old backup, and the next
 * run re-hashes and uploads the new bytes as new content.
 */
@RunWith(RobolectricTestRunner::class)
class EditedPhotoTest {
    private lateinit var provider: FakeMediaProvider
    private lateinit var server: MockWebServer
    private lateinit var db: EngineDb
    private val context: Context get() = ApplicationProvider.getApplicationContext()
    private val assets = Collections.synchronizedMap(HashMap<String, String>())
    private val requests = Collections.synchronizedList(mutableListOf<RecordedRequest>())

    @Before fun setUp() {
        provider = FakeMediaProvider.install()
        server = MockWebServer()
        server.dispatcher =
            object : Dispatcher() {
                var refreshes = 0

                override fun dispatch(request: RecordedRequest): MockResponse {
                    val path = request.url.encodedPath
                    if (path == "/api/v1/auth/refresh") return json(200, tokens(++refreshes))
                    if (path == "/api/v1/server/info") return json(200, """{"server_id":"s"}""")
                    requests += request
                    return when {
                        path == "/api/v1/sync/check" -> {
                            val shas = Regex("\"sha256\":\"([0-9a-f]+)\"").findAll(request.body!!.utf8()).map { it.groupValues[1] }
                            val results =
                                shas.joinToString(",") { s ->
                                    val asset = assets[s]
                                    if (asset == null) {
                                        """{"sha256":"$s","verdict":"missing"}"""
                                    } else {
                                        """{"sha256":"$s","verdict":"exists","asset_id":"$asset","asset_state":"active","on_disk":true}"""
                                    }
                                }
                            json(200, """{"results":[$results]}""")
                        }
                        path == "/api/v1/uploads" && request.method == "POST" -> {
                            val s = metaOf(request)["sha256"]!!
                            val asset = "asset-${assets.size + 1}"
                            assets[s] = asset
                            MockResponse
                                .Builder()
                                .code(201)
                                .addHeader("Tus-Resumable", "1.0.0")
                                .addHeader("Location", "/api/v1/uploads/u${assets.size}")
                                .addHeader("Upload-Offset", request.headers["Upload-Length"]!!)
                                .addHeader("PicTunnel-Asset-Id", asset)
                                .addHeader("PicTunnel-Asset-Created", "true")
                                .build()
                        }
                        else -> MockResponse.Builder().code(500).build()
                    }
                }
            }
        server.start()
        db =
            Room
                .inMemoryDatabaseBuilder(context, EngineDb::class.java)
                .allowMainThreadQueries()
                .build()
    }

    @After fun tearDown() {
        db.close()
        server.close()
    }

    private fun controller(): EngineController {
        val store = FakeStore(credsFor(server.base()))
        val endpoints = Endpoints(store.creds!!.endpoints)
        val clock = FakeClock()
        val auth = AuthManager(store, OkHttpClient(), { clock.monotonicMs() }, CLIENT, endpoints)
        val settings = SettingsRepo(db.settings())
        return EngineController(
            db = db,
            scanner = MediaStoreScanner(context.contentResolver, { settings.get() }, FakeVolumes(provider), { MediaAccess.Full }, 34),
            media = ContentMediaSource(context, requireOriginal = { false }),
            client = ServerClient(endpoints, auth, OkHttpClient(), CLIENT),
            settings = settings,
            clock = clock,
            events = RecordingEvents(),
            config = EngineConfig(chunkBytes = 1 shl 20, random = java.util.Random(1)),
        )
    }

    @Test fun editedPhotoRehashedAndNotFreed() =
        runBlocking {
            val original = "original pixels".toByteArray()
            val edited = "edited pixels, cropped".toByteArray()
            val id = provider.add(bytes = original, modifiedSec = 1_700_000_000)
            val localId = "external_primary:image:$id"
            val engine = controller()

            engine.runOnce(RunBudget())
            val first = db.items().get(localId)!!
            assertEquals(ItemState.BackedUp, first.state)
            assertEquals(sha(original), first.sha256)

            // Edited in place: same id, new bytes and modification time. No scan has run yet.
            provider.edit(id, edited, 1_700_000_900)
            val deleted = mutableListOf<String>()
            val result = engine.freeUpSpace(null, Deleter { ids -> deleted += ids; ids.toSet() })
            assertTrue("the delete dialog must not be shown for changed bytes", deleted.isEmpty())
            assertEquals(0, result.freedCount)
            assertEquals("fingerprint_changed", result.skipped.single().reason)
            assertTrue(provider.exists(id))
            assertEquals(ItemState.Discovered, db.items().get(localId)!!.state)

            // The next run re-hashes the new bytes and backs them up as new content.
            engine.runOnce(RunBudget())
            val after = db.items().get(localId)!!
            assertEquals(ItemState.BackedUp, after.state)
            assertEquals(sha(edited), after.sha256)
            assertNotEquals(first.assetId, after.assetId)
            val posts = requests.filter { it.method == "POST" && it.url.encodedPath == "/api/v1/uploads" }
            assertEquals(listOf(sha(original), sha(edited)), posts.map { metaOf(it)["sha256"] })
            assertEquals(String(edited), posts.last().body!!.utf8())
            assertTrue("the old asset stays on the server", requests.none { it.method == "DELETE" })

            // Now that the edited bytes are proven on the server, freeing works.
            val freed = engine.freeUpSpace(null, Deleter { ids -> ids.forEach { provider.remove(it.substringAfterLast(':').toLong()) }; ids.toSet() })
            assertEquals(1, freed.freedCount)
            assertEquals(ItemState.Freed, db.items().get(localId)!!.state)
        }
}
