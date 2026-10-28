package io.github.prithvirajg.pictunnel.engine.core

import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import io.github.prithvirajg.pictunnel.engine.hash.Sha256
import io.github.prithvirajg.pictunnel.engine.model.ItemKind
import io.github.prithvirajg.pictunnel.engine.model.ItemState
import io.github.prithvirajg.pictunnel.engine.model.PairRole
import io.github.prithvirajg.pictunnel.engine.model.PauseReason
import io.github.prithvirajg.pictunnel.engine.net.AuthManager
import io.github.prithvirajg.pictunnel.engine.net.CLIENT
import io.github.prithvirajg.pictunnel.engine.net.Endpoints
import io.github.prithvirajg.pictunnel.engine.net.FakeStore
import io.github.prithvirajg.pictunnel.engine.net.ServerClient
import io.github.prithvirajg.pictunnel.engine.net.base
import io.github.prithvirajg.pictunnel.engine.net.credsFor
import io.github.prithvirajg.pictunnel.engine.net.json
import io.github.prithvirajg.pictunnel.engine.net.problem
import io.github.prithvirajg.pictunnel.engine.net.tokens
import io.github.prithvirajg.pictunnel.engine.store.EngineDb
import io.github.prithvirajg.pictunnel.engine.store.ItemEntity
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.runBlocking
import mockwebserver3.Dispatcher
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import mockwebserver3.RecordedRequest
import okhttp3.Interceptor
import okhttp3.OkHttpClient
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import java.io.ByteArrayInputStream
import java.io.InputStream
import java.util.Base64
import java.util.Collections
import java.util.concurrent.TimeUnit
import javax.net.ssl.SSLHandshakeException

// ---- fakes shared with the integration test --------------------------------

class FakeClock(
    var now: Long = 1_760_000_000_000L,
) : Clock {
    var mono = 1_000L

    override fun nowMs(): Long = now

    override fun monotonicMs(): Long = mono

    fun advance(ms: Long) {
        now += ms
        mono += ms
    }
}

/** Media keyed by local id; counts every open so tests can assert what was re-read. */
class FakeMedia : MediaSource {
    val bytes = Collections.synchronizedMap(LinkedHashMap<String, ByteArray>())
    val modified = Collections.synchronizedMap(HashMap<String, Long>())
    val opens = Collections.synchronizedList(mutableListOf<String>())
    var onOpen: (String) -> Unit = {}

    fun put(
        localId: String,
        content: ByteArray,
        modifiedAtMs: Long = 100,
    ) {
        bytes[localId] = content
        modified[localId] = modifiedAtMs
    }

    override fun open(localId: String): InputStream {
        onOpen(localId)
        opens += localId
        return ByteArrayInputStream(bytes[localId] ?: throw java.io.FileNotFoundException(localId))
    }

    override fun fingerprint(localId: String): Fingerprint? {
        val b = bytes[localId] ?: return null
        return Fingerprint(modified[localId] ?: 0, b.size.toLong())
    }

    override fun openSeekable(localId: String) =
        io.github.prithvirajg.pictunnel.engine.net.UploadBody
            .of(bytes[localId]!!)
}

/** Reports every item of [media] on each scan (a full rescan), with fixed metadata. */
class FakeScanner(
    private val media: FakeMedia,
    private val meta: (String) -> ScannedItem? = { null },
) : Scanner {
    var scans = 0

    override suspend fun scan(since: List<ScanCursor>): ScanResult {
        scans++
        val items =
            media.bytes.keys.toList().mapIndexed { i, id ->
                meta(id) ?: ScannedItem(
                    localId = id,
                    size = media.bytes[id]!!.size.toLong(),
                    modifiedAtMs = media.modified[id] ?: 0,
                    takenAtMs = 1_000L + i,
                    mime = "image/jpeg",
                    kind = ItemKind.PHOTO,
                    filename = "$id.jpg",
                )
            }
        return ScanResult(items, emptyList(), listOf(ScanCursor("external", scans.toLong(), "v1")), fullRescan = true)
    }
}

class RecordingEvents : EngineEvents {
    val statuses = Collections.synchronizedList(mutableListOf<BackupStatus>())
    val changed = Collections.synchronizedList(mutableListOf<ItemEntity>())
    var repairs = 0

    override fun status(s: BackupStatus) {
        statuses += s
    }

    override fun itemChanged(i: ItemEntity) {
        changed += i
    }

    override fun needsRepair() {
        repairs++
    }
}

fun sha(b: ByteArray): String = Sha256.hex(b)

fun metaOf(r: RecordedRequest): Map<String, String> =
    (r.headers["Upload-Metadata"] ?: "")
        .split(",")
        .filter { it.isNotBlank() }
        .associate {
            val (k, v) = it.trim().split(" ", limit = 2).let { p -> p[0] to p.getOrElse(1) { "" } }
            k to String(Base64.getDecoder().decode(v), Charsets.UTF_8)
        }

@RunWith(RobolectricTestRunner::class)
class PipelineTest {
    private lateinit var server: MockWebServer
    private lateinit var db: EngineDb
    private val media = FakeMedia()
    private val clock = FakeClock()
    private val events = RecordingEvents()
    private val requests = Collections.synchronizedList(mutableListOf<RecordedRequest>())
    private var handler: (RecordedRequest) -> MockResponse = { MockResponse.Builder().code(500).build() }
    private var scannerMeta: (String) -> ScannedItem? = { null }
    private var interceptor: Interceptor? = null

    @Before fun setUp() {
        server = MockWebServer()
        server.dispatcher =
            object : Dispatcher() {
                var refreshes = 0

                override fun dispatch(request: RecordedRequest): MockResponse {
                    val path = request.url.encodedPath
                    if (path == "/api/v1/auth/refresh") return json(200, tokens(++refreshes))
                    if (path == "/api/v1/server/info") return json(200, """{"server_id":"s","upload":{"recommended_chunk_bytes":8}}""")
                    requests += request
                    return handler(request)
                }
            }
        server.start()
        db =
            Room
                .inMemoryDatabaseBuilder(ApplicationProvider.getApplicationContext(), EngineDb::class.java)
                .allowMainThreadQueries()
                .build()
    }

    @After fun tearDown() {
        db.close()
        server.close()
    }

    private fun controller(
        base: String = server.base(),
        chunk: Long? = 8,
        checkBatch: Int = 1000,
        maxPasses: Int = 20,
    ): EngineController {
        val store = FakeStore(credsFor(base))
        val endpoints = Endpoints(store.creds!!.endpoints)
        val auth = AuthManager(store, OkHttpClient(), { clock.monotonicMs() }, CLIENT, endpoints)
        val http =
            OkHttpClient
                .Builder()
                .readTimeout(500, TimeUnit.MILLISECONDS)
                .apply { interceptor?.let { addInterceptor(it) } }
                .build()
        val client = ServerClient(endpoints, auth, http, CLIENT)
        return EngineController(
            db = db,
            scanner = FakeScanner(media) { scannerMeta(it) },
            media = media,
            client = client,
            settings = SettingsRepo(db.settings()),
            clock = clock,
            events = events,
            config =
                EngineConfig(chunkBytes = chunk, checkBatchSize = checkBatch, random = java.util.Random(7), maxPasses = maxPasses),
        )
    }

    private fun item(id: String): ItemEntity = runBlocking { db.items().get(id)!! }

    private fun checkBody(vararg results: String) = json(200, """{"results":[${results.joinToString(",")}]}""")

    /** Answers a check request in its own item order. */
    private fun answer(
        r: RecordedRequest,
        result: (String) -> String,
    ): MockResponse {
        val shas = Regex("\"sha256\":\"([0-9a-f]+)\"").findAll(r.body!!.utf8()).map { it.groupValues[1] }.toList()
        return checkBody(*shas.map(result).toTypedArray())
    }

    private fun missing(s: String) = """{"sha256":"$s","verdict":"missing"}"""

    private fun exists(
        s: String,
        asset: String,
        live: Boolean? = null,
    ) = """{"sha256":"$s","verdict":"exists","asset_id":"$asset","asset_state":"active"""" +
        (live?.let { ""","has_live_video":$it""" } ?: "") + "}"

    private fun created(
        id: String,
        offset: Long,
        asset: String? = null,
    ) = MockResponse
        .Builder()
        .code(201)
        .addHeader("Tus-Resumable", "1.0.0")
        .addHeader("Location", "/api/v1/uploads/$id")
        .addHeader("Upload-Offset", offset)
        .apply { if (asset != null) addHeader("PicTunnel-Asset-Id", asset).addHeader("PicTunnel-Asset-Created", "true") }
        .build()

    private fun patched(
        offset: Long,
        asset: String? = null,
    ) = MockResponse
        .Builder()
        .code(204)
        .addHeader("Upload-Offset", offset)
        .apply { if (asset != null) addHeader("PicTunnel-Asset-Id", asset) }
        .build()

    private fun RecordedRequest.isCheck() = url.encodedPath == "/api/v1/sync/check"

    private fun RecordedRequest.line() = "$method ${url.encodedPath}"

    // ---- tests -------------------------------------------------------------

    @Test fun freshUploadToBackedUp() =
        runBlocking {
            val bytes = "hello world".toByteArray()
            media.put("a", bytes)
            handler = { r ->
                when {
                    r.isCheck() -> checkBody(missing(sha(bytes)))
                    r.method == "POST" -> created("u1", bytes.size.toLong(), "asset-1")
                    else -> MockResponse.Builder().code(500).build()
                }
            }
            val report = controller(chunk = 1024).runOnce(RunBudget())

            val a = item("a")
            assertEquals(ItemState.BackedUp, a.state)
            assertEquals("asset-1", a.assetId)
            assertEquals(sha(bytes), a.sha256)
            assertEquals(listOf("POST /api/v1/sync/check", "POST /api/v1/uploads"), requests.map { it.line() })
            val post = requests[1]
            assertEquals(bytes.size.toLong(), post.headers["Upload-Length"]!!.toLong())
            assertEquals(String(bytes), post.body!!.utf8())
            val meta = metaOf(post)
            assertEquals(sha(bytes), meta["sha256"])
            assertEquals("a.jpg", meta["filename"])
            assertEquals("image/jpeg", meta["mime"])
            assertEquals("a", meta["local_id"])
            assertNull(meta["pair_role"])
            assertTrue(requests.all { it.headers["PicTunnel-Client"] == CLIENT })
            assertEquals(1, report.backedUp)
            assertEquals(StopReason.Idle, report.stop)
            assertEquals(sha(bytes), db.hashCache().lookup("a", 100, bytes.size.toLong()))
            assertTrue(db.activity().latest(10).any { it.kind == ActivityLog.BACKED_UP && it.localId == "a" })
            val status = events.statuses.last()
            assertEquals(1, status.backedUp)
            assertEquals(1, status.total)
            assertEquals(bytes.size.toLong(), status.freeableBytes)
        }

    @Test fun existsVerdictNoUpload() =
        runBlocking {
            val bytes = "x".toByteArray()
            media.put("a", bytes)
            handler = { r -> if (r.isCheck()) checkBody(exists(sha(bytes), "asset-9")) else MockResponse.Builder().code(500).build() }
            controller().runOnce(RunBudget())
            assertEquals(ItemState.BackedUp, item("a").state)
            assertEquals("asset-9", item("a").assetId)
            assertEquals(listOf("POST /api/v1/sync/check"), requests.map { it.line() })
            // local_id is sent so the server links the existing asset (P§7.2).
            assertTrue(requests[0].body!!.utf8().contains("\"local_id\":\"a\""))
        }

    @Test fun partialVerdictResumes() =
        runBlocking {
            val bytes = ByteArray(20) { it.toByte() }
            media.put("a", bytes)
            handler = { r ->
                when {
                    r.isCheck() ->
                        checkBody(
                            """{"sha256":"${sha(bytes)}","verdict":"partial","upload":{"id":"u1","url":"/api/v1/uploads/u1","offset":8,"length":20}}""",
                        )
                    r.method == "PATCH" && r.headers["Upload-Offset"] == "8" -> patched(16)
                    r.method == "PATCH" && r.headers["Upload-Offset"] == "16" -> patched(20, "asset-2")
                    else -> MockResponse.Builder().code(500).build()
                }
            }
            controller().runOnce(RunBudget())
            assertEquals(ItemState.BackedUp, item("a").state)
            assertEquals("asset-2", item("a").assetId)
            assertEquals(
                listOf("POST /api/v1/sync/check", "PATCH /api/v1/uploads/u1", "PATCH /api/v1/uploads/u1"),
                requests.map { it.line() },
            )
            assertEquals(bytes.copyOfRange(8, 16).toList(), requests[1].body!!.toByteArray().toList())
        }

    @Test fun tombstonedSkipped() =
        runBlocking {
            val bytes = "t".toByteArray()
            media.put("a", bytes)
            handler = { r ->
                if (r.isCheck()) checkBody("""{"sha256":"${sha(bytes)}","verdict":"tombstoned","deleted_at":"2026-10-01T00:00:00Z"}""") else MockResponse.Builder().code(500).build()
            }
            val report = controller().runOnce(RunBudget())
            assertEquals(ItemState.Skipped, item("a").state)
            assertEquals(1, report.skipped)
            assertEquals(1, requests.size)
        }

    @Test fun timeoutWithUploadIdHeads() =
        runBlocking {
            val bytes = ByteArray(20) { (it * 3).toByte() }
            media.put("a", bytes)
            var patches = 0
            handler = { r ->
                when {
                    r.isCheck() -> checkBody(missing(sha(bytes)))
                    r.method == "POST" -> created("u1", 0)
                    r.method == "PATCH" && patches++ == 0 ->
                        // The server took the bytes but the answer never arrives: a read timeout.
                        MockResponse.Builder().code(204).addHeader("Upload-Offset", 8).headersDelay(3, TimeUnit.SECONDS).build()
                    r.method == "HEAD" -> MockResponse.Builder().code(200).addHeader("Upload-Offset", 8).addHeader("Upload-Length", 20).build()
                    r.method == "PATCH" && r.headers["Upload-Offset"] == "8" -> patched(16)
                    r.method == "PATCH" && r.headers["Upload-Offset"] == "16" -> patched(20, "asset-3")
                    else -> MockResponse.Builder().code(500).build()
                }
            }
            controller().runOnce(RunBudget())
            val a = item("a")
            assertEquals(ItemState.BackedUp, a.state)
            assertEquals(
                listOf(
                    "POST /api/v1/sync/check",
                    "POST /api/v1/uploads",
                    "PATCH /api/v1/uploads/u1",
                    "HEAD /api/v1/uploads/u1",
                    "PATCH /api/v1/uploads/u1",
                    "PATCH /api/v1/uploads/u1",
                ),
                requests.map { it.line() },
            )
        }

    @Test fun timeoutWithoutUploadIdChecks() =
        runBlocking {
            val bytes = "single shot".toByteArray()
            media.put("a", bytes)
            var checks = 0
            handler = { r ->
                when {
                    r.isCheck() && checks++ == 0 -> checkBody(missing(sha(bytes)))
                    r.isCheck() -> checkBody(exists(sha(bytes), "asset-4"))
                    r.method == "POST" -> created("u1", bytes.size.toLong(), "asset-4").newBuilder().headersDelay(3, TimeUnit.SECONDS).build()
                    else -> MockResponse.Builder().code(500).build()
                }
            }
            controller(chunk = 1024).runOnce(RunBudget())
            assertEquals(ItemState.BackedUp, item("a").state)
            assertEquals("asset-4", item("a").assetId)
            assertEquals(0, item("a").attempts) // reset once backed up
            assertEquals(
                listOf("POST /api/v1/sync/check", "POST /api/v1/uploads", "POST /api/v1/sync/check"),
                requests.map { it.line() },
            )
        }

    @Test fun tenFailuresNeedsAttention() =
        runBlocking {
            media.put("a", "z".toByteArray())
            handler = { problem(500, "internal") }
            val c = controller()
            repeat(9) {
                c.runOnce(RunBudget())
                assertEquals(ItemState.Hashed, item("a").state)
                assertEquals(it + 1, item("a").attempts)
                assertNotNull(item("a").nextAttemptAtMs)
                clock.advance(60 * 60 * 1000L)
            }
            c.runOnce(RunBudget())
            assertEquals(ItemState.NeedsAttention, item("a").state)
            assertEquals(10, item("a").attempts)
            assertEquals(10, requests.size)
            assertEquals(1, c.listAttention().size)
            assertEquals("internal", c.listAttention()[0].code)
        }

    @Test fun offlineDoesNotCountAttempt() =
        runBlocking {
            media.put("a", "o".toByteArray())
            val dead = MockWebServer().apply { start() }
            val base = dead.base()
            dead.close()
            val report = controller(base = base).runOnce(RunBudget())
            assertEquals(StopReason.Offline, report.stop)
            assertEquals(ItemState.Hashed, item("a").state)
            assertEquals(0, item("a").attempts)
            assertNull(item("a").nextAttemptAtMs)
        }

    @Test fun insufficientStoragePausesAll() =
        runBlocking {
            for (i in 0 until 5) media.put("i$i", "item $i".toByteArray())
            handler = { r ->
                when {
                    r.isCheck() -> answer(r) { missing(it) }
                    r.method == "POST" -> problem(507, "insufficient_storage")
                    else -> MockResponse.Builder().code(500).build()
                }
            }
            val c = controller(chunk = 1024)
            val report = c.runOnce(RunBudget())
            assertEquals(StopReason.Paused, report.stop)
            val posts = requests.count { it.method == "POST" && !it.isCheck() }
            assertTrue("at most the 2 in-flight creates, got $posts", posts in 1..2)
            for (i in 0 until 5) {
                assertEquals(0, item("i$i").attempts)
                assertFalse(item("i$i").state == ItemState.NeedsAttention)
            }
            val status = c.status()
            assertTrue(status.paused)
            assertEquals(PauseReason.ServerFull, status.pauseReason)
            // A paused engine sends nothing until resumed.
            requests.clear()
            assertEquals(StopReason.Paused, c.runOnce(RunBudget()).stop)
            assertTrue(requests.isEmpty())
        }

    @Test fun hashingResumesFromCache() =
        runBlocking {
            for (i in 0 until 6) media.put("h$i", "content $i".toByteArray())
            handler = { r ->
                if (r.isCheck()) {
                    val shas = Regex("\"sha256\":\"([0-9a-f]+)\"").findAll(r.body!!.utf8()).map { it.groupValues[1] }.toList()
                    checkBody(*shas.map { missing(it) }.toTypedArray())
                } else {
                    MockResponse.Builder().code(500).build()
                }
            }
            // The first run is killed after the third file was opened.
            media.onOpen = { if (media.opens.size == 3) throw CancellationException("killed") }
            runCatching { controller().runOnce(RunBudget()) }
            val firstOpens = media.opens.toList()
            assertEquals(3, firstOpens.size)
            // Simulate a crash between the cache write and the item write for one item.
            val hashedBefore = db.items().byState(listOf(ItemState.Hashed), 100).map { it.localId }
            assertEquals(3, hashedBefore.size)
            db.items().upsert(item(hashedBefore[0]).copy(state = ItemState.Discovered, sha256 = null))

            media.onOpen = {}
            media.opens.clear()
            controller().runOnce(RunBudget(maxUploads = 0))
            // Only the never-hashed files are read again; cached ones are not.
            assertEquals(3, media.opens.size)
            assertTrue(media.opens.none { it in hashedBefore })
            assertEquals(6, db.items().byState(listOf(ItemState.Queued), 100).size)
        }

    @Test fun livePhotoPrimaryFirst() =
        runBlocking {
            val still = "still".toByteArray()
            val video = "video bytes".toByteArray()
            media.put("p", still)
            media.put("v", video)
            scannerMeta = { id ->
                ScannedItem(
                    localId = id,
                    size = media.bytes[id]!!.size.toLong(),
                    modifiedAtMs = 100,
                    takenAtMs = 5_000,
                    mime = if (id == "p") "image/heic" else "video/quicktime",
                    kind = ItemKind.LIVE_PHOTO,
                    filename = if (id == "p") "IMG_1.HEIC" else "IMG_1.MOV",
                    pairRole = if (id == "p") PairRole.PRIMARY else PairRole.LIVE_VIDEO,
                    pairLocalId = if (id == "p") "v" else "p",
                )
            }
            val order = Collections.synchronizedList(mutableListOf<String>())
            handler = { r ->
                when {
                    r.isCheck() -> answer(r) { missing(it) }
                    r.method == "POST" -> {
                        val m = metaOf(r)
                        order += m["filename"]!!
                        if (m["pair_role"] == "live_video") {
                            created("uv", video.size.toLong(), "asset-p")
                        } else {
                            Thread.sleep(200) // the video must wait for this answer
                            order += "primary-done"
                            created("up", still.size.toLong(), "asset-p")
                        }
                    }
                    else -> MockResponse.Builder().code(500).build()
                }
            }
            controller(chunk = 1024).runOnce(RunBudget())
            assertEquals(listOf("IMG_1.HEIC", "primary-done", "IMG_1.MOV"), order.toList())
            val videoPost = requests.first { it.method == "POST" && metaOf(it)["filename"] == "IMG_1.MOV" }
            assertEquals("live_video", metaOf(videoPost)["pair_role"])
            assertEquals(sha(still), metaOf(videoPost)["pair_sha256"])
            assertEquals(ItemState.BackedUp, item("p").state)
            assertEquals(ItemState.BackedUp, item("v").state)
            // The paired video is a hidden component of the timeline.
            assertEquals(listOf("p"), controller().listPhoneItems(null, 10).items.map { it.localId })
        }

    // ---- carried requirements ----------------------------------------------

    @Test fun pinMismatchPausesWithoutBurningAttempts() =
        runBlocking {
            for (i in 0 until 3) media.put("i$i", "tls $i".toByteArray())
            interceptor = Interceptor { throw SSLHandshakeException("pin mismatch") }
            val c = controller()
            val report = c.runOnce(RunBudget())
            assertEquals(StopReason.ServerUntrusted, report.stop)
            for (i in 0 until 3) {
                assertEquals(0, item("i$i").attempts)
                assertEquals(ItemState.Hashed, item("i$i").state)
            }
            val status = c.status()
            assertTrue(status.paused)
            assertEquals(EngineController.UNTRUSTED_PAUSE_REASON, status.pauseReason)
            assertTrue(c.listActivity(10).any { it.message.contains("server certificate changed") })
            assertEquals(0, events.repairs)
        }

    @Test fun headFinalizingResolvesViaCheck() =
        runBlocking {
            val bytes = ByteArray(16) { 1 }
            media.put("a", bytes)
            var checks = 0
            handler = { r ->
                when {
                    r.isCheck() && checks++ == 0 -> checkBody(missing(sha(bytes)))
                    r.isCheck() -> checkBody(exists(sha(bytes), "asset-f"))
                    r.method == "POST" -> created("u1", 0)
                    r.method == "PATCH" && r.headers["Upload-Offset"] == "0" -> patched(8)
                    // The final PATCH resets; HEAD then sees all bytes but finalize is still running.
                    r.method == "PATCH" ->
                        MockResponse.Builder().code(204).addHeader("Upload-Offset", 16).headersDelay(3, TimeUnit.SECONDS).build()
                    r.method == "HEAD" -> MockResponse.Builder().code(200).addHeader("Upload-Offset", 16).addHeader("Upload-Length", 16).build()
                    else -> MockResponse.Builder().code(500).build()
                }
            }
            controller().runOnce(RunBudget())
            assertEquals(ItemState.BackedUp, item("a").state)
            assertEquals("asset-f", item("a").assetId)
            val lines = requests.map { it.line() }
            assertEquals("HEAD /api/v1/uploads/u1", lines[lines.size - 2])
            assertEquals("POST /api/v1/sync/check", lines.last())
            assertEquals(2, lines.count { it.startsWith("PATCH") })
        }

    @Test fun head404RestartsWithPost() =
        runBlocking {
            val bytes = ByteArray(12) { 2 }
            media.put("a", bytes)
            var posts = 0
            handler = { r ->
                when {
                    r.isCheck() -> checkBody(missing(sha(bytes)))
                    r.method == "POST" && posts++ == 0 -> created("u1", 0)
                    r.method == "POST" -> created("u2", 0)
                    r.method == "PATCH" && r.url.encodedPath.endsWith("u1") -> MockResponse.Builder().code(204).headersDelay(3, TimeUnit.SECONDS).build()
                    r.method == "HEAD" -> MockResponse.Builder().code(404).build()
                    r.method == "PATCH" && r.headers["Upload-Offset"] == "0" -> patched(8)
                    r.method == "PATCH" -> patched(12, "asset-r")
                    else -> MockResponse.Builder().code(500).build()
                }
            }
            controller().runOnce(RunBudget())
            assertEquals(ItemState.BackedUp, item("a").state)
            assertEquals(2, posts)
        }

    @Test fun checkBatchesAreBounded() =
        runBlocking {
            for (i in 0 until 7) media.put("b$i", "batch $i".toByteArray())
            handler = { r ->
                val shas = Regex("\"sha256\":\"([0-9a-f]+)\"").findAll(r.body!!.utf8()).map { it.groupValues[1] }.toList()
                checkBody(*shas.map { exists(it, "x-$it") }.toTypedArray())
            }
            controller(checkBatch = 3).runOnce(RunBudget())
            assertEquals(listOf(3, 3, 1), requests.map { Regex("\"sha256\"").findAll(it.body!!.utf8()).count() })
            assertEquals(7, db.items().byState(listOf(ItemState.BackedUp), 100).size)
        }

    @Test fun freeUpSpaceAppliesFreedOnlyAfterConfirmation() =
        runBlocking {
            val a = "aaa".toByteArray()
            val b = "bbbb".toByteArray()
            val c = "ccccc".toByteArray()
            media.put("a", a)
            media.put("b", b)
            media.put("c", c)
            handler = { r ->
                val body = r.body!!.utf8()
                val shas = Regex("\"sha256\":\"([0-9a-f]+)\"").findAll(body).map { it.groupValues[1] }.toList()
                if (body.contains("\"confirm_on_disk\":true")) {
                    checkBody(
                        *shas
                            .map { s ->
                                if (s == sha(c)) {
                                    """{"sha256":"$s","verdict":"exists","asset_id":"x","asset_state":"active","on_disk":false}"""
                                } else {
                                    """{"sha256":"$s","verdict":"exists","asset_id":"x","asset_state":"active","on_disk":true}"""
                                }
                            }.toTypedArray(),
                    )
                } else {
                    checkBody(*shas.map { exists(it, "x") }.toTypedArray())
                }
            }
            val ctl = controller()
            ctl.runOnce(RunBudget())
            val asked = mutableListOf<List<String>>()
            // The user confirms "a" and cancels "b" in the OS dialog.
            val result =
                ctl.freeUpSpace(null) { ids ->
                    asked += ids
                    setOf("a")
                }
            assertEquals(listOf(listOf("a", "b").sorted()), asked.map { it.sorted() })
            assertEquals(ItemState.Freed, item("a").state)
            assertEquals(ItemState.BackedUp, item("b").state)
            assertEquals(ItemState.BackedUp, item("c").state)
            assertEquals(1, result.freedCount)
            assertEquals(a.size.toLong(), result.freedBytes)
            assertEquals(setOf("b" to "cancelled", "c" to "not_on_server_disk"), result.skipped.map { it.localId to it.reason }.toSet())
        }

    @Test fun freeUpSpaceRefusesChangedFile() =
        runBlocking {
            media.put("a", "orig".toByteArray())
            handler = { r ->
                val shas = Regex("\"sha256\":\"([0-9a-f]+)\"").findAll(r.body!!.utf8()).map { it.groupValues[1] }.toList()
                checkBody(*shas.map { """{"sha256":"$it","verdict":"exists","asset_id":"x","asset_state":"active","on_disk":true}""" }.toTypedArray())
            }
            val ctl = controller()
            ctl.runOnce(RunBudget())
            media.put("a", "edited!".toByteArray(), modifiedAtMs = 200)
            var called = false
            val result =
                ctl.freeUpSpace(listOf("a")) {
                    called = true
                    it.toSet()
                }
            assertFalse(called)
            assertEquals(0, result.freedCount)
            assertEquals(ItemState.Discovered, item("a").state)
            assertEquals("fingerprint_changed", result.skipped.single().reason)
        }

    @Test fun phoneItemsPageByTakenAtThenLocalId() =
        runBlocking {
            val ctl = controller()
            val rows =
                listOf("a" to 300L, "c" to 200L, "b" to 200L, "d" to 100L).map { (id, t) ->
                    ItemEntity(
                        localId = id, sha256 = null, size = 1, modifiedAtMs = 1, takenAtMs = t, mime = "image/jpeg",
                        kind = ItemKind.PHOTO, pairRole = PairRole.PRIMARY, pairLocalId = null, stackKey = null,
                        state = ItemState.Discovered, attempts = 0, nextAttemptAtMs = null, uploadId = null,
                        uploadUrl = null, uploadOffset = null, assetId = null, lastError = null, filename = id,
                        width = 4, height = 3, durationMs = null,
                    )
                }
            db.items().upsertAll(rows)
            val p1 = ctl.listPhoneItems(null, 2)
            assertEquals(listOf("a", "c"), p1.items.map { it.localId })
            assertEquals("200|c", p1.nextKey)
            val p2 = ctl.listPhoneItems(p1.nextKey, 2)
            assertEquals(listOf("b", "d"), p2.items.map { it.localId })
            assertEquals(4, p2.items[0].width)
            val p3 = ctl.listPhoneItems(p2.nextKey, 2)
            assertTrue(p3.items.isEmpty())
            assertNull(p3.nextKey)
        }

    // ---- review fix round 1 --------------------------------------------------

    @Test fun sameBytesUploadOnce() =
        runBlocking {
            val bytes = "same content in two rows".toByteArray()
            media.put("s1", bytes)
            media.put("s2", bytes)
            handler = { r ->
                when {
                    r.isCheck() -> answer(r) { missing(it) }
                    r.method == "POST" && (r.body?.size ?: 0) > 0 -> {
                        Thread.sleep(150) // keep the first upload in flight while the other row is considered
                        created("u1", bytes.size.toLong(), "asset-s")
                    }
                    // Bodyless create of content the server holds: outcome #3.
                    r.method == "POST" -> created("u1", bytes.size.toLong(), "asset-s")
                    else -> MockResponse.Builder().code(500).build()
                }
            }
            val report = controller(chunk = 1024).runOnce(RunBudget())
            assertEquals(StopReason.Idle, report.stop)
            val posts = requests.filter { it.method == "POST" && !it.isCheck() }
            assertEquals(1, posts.count { (it.body?.size ?: 0) > 0 })
            assertEquals(2, posts.size)
            assertEquals(ItemState.BackedUp, item("s1").state)
            assertEquals(ItemState.BackedUp, item("s2").state)
            assertEquals(0, item("s1").attempts + item("s2").attempts)
        }

    @Test fun outOfPassesReportsBudget() =
        runBlocking {
            // A Live Photo needs two passes (the video waits for its still); allow one.
            media.put("p", "still".toByteArray())
            media.put("v", "video".toByteArray())
            scannerMeta = { id ->
                ScannedItem(
                    localId = id,
                    size = 5,
                    modifiedAtMs = 100,
                    takenAtMs = 5_000,
                    mime = "image/heic",
                    kind = ItemKind.LIVE_PHOTO,
                    filename = id,
                    pairRole = if (id == "p") PairRole.PRIMARY else PairRole.LIVE_VIDEO,
                    pairLocalId = if (id == "p") "v" else "p",
                )
            }
            handler = { r ->
                when {
                    r.isCheck() -> answer(r) { missing(it) }
                    r.method == "POST" -> created("u-${metaOf(r)["local_id"]}", 5, "asset-${metaOf(r)["local_id"]}")
                    else -> MockResponse.Builder().code(500).build()
                }
            }
            val report = controller(chunk = 1024, maxPasses = 1).runOnce(RunBudget())
            assertEquals(StopReason.Budget, report.stop)
            assertEquals(ItemState.BackedUp, item("p").state)
            assertEquals(ItemState.Queued, item("v").state)
        }

    @Test fun rowIsWrittenBeforeEachCall() =
        runBlocking {
            // R1: when a request reaches the server, the row governing it is already stored.
            val bytes = ByteArray(20) { (it + 5).toByte() }
            media.put("a", bytes)
            val violations = Collections.synchronizedList(mutableListOf<String>())
            handler = { r ->
                val row = runBlocking { db.items().get("a") }
                when {
                    r.isCheck() -> {
                        if (!(row?.state == ItemState.Hashed && row.sha256 == sha(bytes))) violations += "check before Hashed: $row"
                        answer(r) { missing(it) }
                    }
                    r.method == "POST" -> {
                        if (row?.state != ItemState.Queued) violations += "create before Queued: $row"
                        created("u1", 0)
                    }
                    r.method == "PATCH" -> {
                        val off = r.headers["Upload-Offset"]!!.toLong()
                        if (!(row?.state == ItemState.Uploading && row.uploadUrl != null && row.uploadOffset == off)) {
                            violations += "PATCH at $off before its row: $row"
                        }
                        if (off + 8 >= 20) patched(20, "asset-r1") else patched(off + 8)
                    }
                    else -> MockResponse.Builder().code(500).build()
                }
            }
            controller().runOnce(RunBudget())
            assertEquals(ItemState.BackedUp, item("a").state)
            assertEquals(3, requests.count { it.method == "PATCH" })
            assertTrue(violations.toString(), violations.isEmpty())
        }

    @Test fun clockJumpBackDoesNotStrandBackoffOrPause() =
        runBlocking {
            media.put("a", "j".toByteArray())
            var fail = true
            handler = { r ->
                when {
                    r.isCheck() && fail -> problem(500, "internal")
                    r.isCheck() -> answer(r) { exists(it, "asset-j") }
                    else -> MockResponse.Builder().code(500).build()
                }
            }
            val c = controller()
            c.runOnce(RunBudget())
            assertNotNull(item("a").nextAttemptAtMs)
            // The device clock jumps a day back: the stored backoff now looks a day away (R10).
            clock.now -= 24 * 60 * 60 * 1000L
            c.runOnce(RunBudget())
            assertEquals(2, requests.count { it.isCheck() })

            // A timed pause cannot outlive a clock jump either.
            fail = false
            SettingsRepo(db.settings()).setPause(PauseState(PauseReason.ServerFull, clock.now + 30 * 60 * 1000L))
            clock.now -= 24 * 60 * 60 * 1000L
            clock.advance(0)
            val report = c.runOnce(RunBudget())
            assertEquals(StopReason.Idle, report.stop)
            assertEquals(ItemState.BackedUp, item("a").state)
        }

    @Test fun skippedRowsNeverHideDueWork() =
        runBlocking {
            // The four newest rows get an answer to skip for this run; the oldest must still be checked.
            for (i in 0 until 5) media.put("k$i", "keyset $i".toByteArray())
            val oldest = sha(media.bytes["k0"]!!)
            handler = { r ->
                answer(r) { s -> if (s == oldest) exists(s, "asset-k") else """{"sha256":"$s","verdict":"exists"}""" }
            }
            controller(checkBatch = 2).runOnce(RunBudget())
            assertEquals(ItemState.BackedUp, item("k0").state)
            for (i in 1 until 5) assertEquals(ItemState.Hashed, item("k$i").state)
        }


    @Test fun activityLogIsARingOf1000() =
        runBlocking {
            val log = ActivityLog(db.activity(), clock)
            repeat(1005) { log.add(ActivityLog.ERROR, "e$it") }
            val all = log.latest(2000)
            assertEquals(1000, all.size)
            assertEquals("e1004", all.first().message)
            assertEquals("e5", all.last().message)
        }
}
