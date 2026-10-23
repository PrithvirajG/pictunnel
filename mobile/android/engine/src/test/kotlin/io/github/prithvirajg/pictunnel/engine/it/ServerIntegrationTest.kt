package io.github.prithvirajg.pictunnel.engine.it

import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import io.github.prithvirajg.pictunnel.engine.core.EngineConfig
import io.github.prithvirajg.pictunnel.engine.core.EngineController
import io.github.prithvirajg.pictunnel.engine.core.FakeClock
import io.github.prithvirajg.pictunnel.engine.core.FakeMedia
import io.github.prithvirajg.pictunnel.engine.core.FakeScanner
import io.github.prithvirajg.pictunnel.engine.core.RecordingEvents
import io.github.prithvirajg.pictunnel.engine.core.RunBudget
import io.github.prithvirajg.pictunnel.engine.core.SettingsRepo
import io.github.prithvirajg.pictunnel.engine.core.StopReason
import io.github.prithvirajg.pictunnel.engine.core.sha
import io.github.prithvirajg.pictunnel.engine.model.ItemState
import io.github.prithvirajg.pictunnel.engine.net.AuthManager
import io.github.prithvirajg.pictunnel.engine.net.CLIENT
import io.github.prithvirajg.pictunnel.engine.net.EngineHttp
import io.github.prithvirajg.pictunnel.engine.net.Endpoints
import io.github.prithvirajg.pictunnel.engine.net.FakeStore
import io.github.prithvirajg.pictunnel.engine.net.ServerClient
import io.github.prithvirajg.pictunnel.engine.pairing.Pairer
import io.github.prithvirajg.pictunnel.engine.store.EngineDb
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.Interceptor
import okhttp3.MediaType
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody
import okhttp3.RequestBody.Companion.toRequestBody
import okio.Buffer
import okio.BufferedSink
import okio.ForwardingSink
import okio.buffer
import org.junit.After
import org.junit.AfterClass
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.BeforeClass
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import java.io.File
import java.io.IOException
import java.net.ServerSocket
import java.nio.file.Files
import java.util.Collections
import java.util.Random
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit

/** A real `pictunnel serve` process on loopback ports with a throwaway data dir. */
class RealServer private constructor(
    private val process: Process,
    val dataDir: File,
    val httpsPort: Int,
    val localPort: Int,
    val pin: String,
) : AutoCloseable {
    private val http = OkHttpClient.Builder().readTimeout(30, TimeUnit.SECONDS).build()
    private val jsonType = "application/json".toMediaType()

    @Volatile lateinit var adminToken: String
        private set

    /** Calls the loopback listener, where setup needs no token (P§6.3). */
    fun local(
        method: String,
        path: String,
        body: String? = null,
        token: String? = adminToken,
    ): Pair<Int, JsonObject?> {
        val req =
            Request
                .Builder()
                .url("http://127.0.0.1:$localPort$path")
                .header("PicTunnel-Client", CLIENT)
                .header("Tus-Resumable", "1.0.0")
                .apply { if (token != null) header("Authorization", "Bearer $token") }
                .method(method, body?.toRequestBody(jsonType) ?: if (method == "POST") ByteArray(0).toRequestBody(null) else null)
                .build()
        http.newCall(req).execute().use { r ->
            val text = r.body.string()
            val json = if (text.isNotBlank() && text.trimStart().startsWith("{")) Json.parseToJsonElement(text).jsonObject else null
            return r.code to json
        }
    }

    fun setupAdmin() {
        val (s, _) =
            local(
                "POST",
                "/api/v1/auth/setup",
                """{"username":"alice","password":"correct horse battery","display_name":"Alice"}""",
                token = null,
            )
        check(s == 201) { "setup answered $s" }
        val (l, body) =
            local(
                "POST",
                "/api/v1/auth/login",
                """{"username":"alice","password":"correct horse battery","mode":"tokens",""" +
                    """"device":{"device_name":"it-admin","platform":"other","app_version":"0.1.0"}}""",
                token = null,
            )
        check(l == 200) { "login answered $l: $body" }
        adminToken = body!!["tokens"]!!.jsonObject["access_token"]!!.jsonPrimitive.content
    }

    /** A fresh pairing code's QR URI. */
    fun pairingUri(): String {
        val (s, body) = local("POST", "/api/v1/pairing/codes")
        check(s == 201) { "pairing code answered $s: $body" }
        return body!!["qr_uri"]!!.jsonPrimitive.content
    }

    /** Active and trashed assets of the admin with this content hash. */
    fun assetsWithSha(sha256: String): List<JsonObject> {
        val (s, body) = local("GET", "/api/v1/sync/snapshot?limit=1000")
        check(s == 200) { "snapshot answered $s" }
        return body!!["assets"]!!.jsonArray.map { it.jsonObject }.filter { it["sha256"]?.jsonPrimitive?.content == sha256 }
    }

    override fun close() {
        process.destroy()
        if (!process.waitFor(10, TimeUnit.SECONDS)) process.destroyForcibly()
        dataDir.deleteRecursively()
    }

    companion object {
        private fun freePort(): Int = ServerSocket(0).use { it.localPort }

        fun start(bin: String): RealServer {
            val data = Files.createTempDirectory("pictunnel-it").toFile()
            val https = freePort()
            val local = freePort()
            val pb =
                ProcessBuilder(
                    bin,
                    "serve",
                    "--data-dir=${data.absolutePath}",
                    "--server.https-addr=127.0.0.1:$https",
                    "--server.local-addr=127.0.0.1:$local",
                    "--discovery.mdns=false",
                    // The QR then names the loopback HTTPS listener after the (unreachable) interface IPs.
                    "--server.public-urls=https://127.0.0.1:$https",
                    "--rate-limit.enabled=false",
                    "--upload.recommended-chunk-bytes=1048576",
                    "--storage.reserve-bytes=0",
                    "--log.level=warn",
                ).redirectError(File(data, "stderr.log"))
            val p = pb.start()
            val lines = LinkedBlockingQueue<String>()
            Thread {
                p.inputStream.bufferedReader().forEachLine { lines.put(it) }
            }.apply { isDaemon = true }.start()
            var pin: String? = null
            var listening = false
            var setupToken: String? = null
            val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(60)
            // The setup token line follows the listening line on a fresh data dir.
            while (pin == null || !listening || setupToken == null) {
                val left = deadline - System.nanoTime()
                val line = lines.poll(left.coerceAtLeast(0), TimeUnit.NANOSECONDS)
                if (line == null) {
                    p.destroyForcibly()
                    error("server did not start: ${File(data, "stderr.log").readText()}")
                }
                when {
                    line.contains("certificate pin ") -> pin = line.substringAfter("certificate pin ").trim()
                    line.contains(" listening on ") -> listening = true
                    line.contains("PicTunnel-Setup-Token:") -> setupToken = line.substringAfter("PicTunnel-Setup-Token:").trim()
                }
            }
            check(setupToken.isNotEmpty()) { "a fresh server prints a setup token" }
            return RealServer(p, data, https, local, pin).also { it.setupAdmin() }
        }
    }
}

/**
 * Network faults for uploads. [dropPatch] makes the n-th PATCH (1-based) fail
 * after [dropAfterBytes] body bytes (0: before anything is sent), once, after
 * the connection is up; [beforeDrop] runs just before that failure.
 */
class Chaos : Interceptor {
    val lines: MutableList<String> = Collections.synchronizedList(mutableListOf())

    /** Upload requests (POST /uploads and PATCH) that carried body bytes. */
    val bodyUploads: MutableList<String> = Collections.synchronizedList(mutableListOf())

    @Volatile var dropPatch = 0

    @Volatile var dropAfterBytes = 0L

    @Volatile var beforeDrop: (Request) -> Unit = {}

    private var patches = 0

    override fun intercept(chain: Interceptor.Chain): okhttp3.Response {
        val req = chain.request()
        lines += "${req.method} ${req.url.encodedPath}"
        val uploading = req.method == "PATCH" || (req.method == "POST" && req.url.encodedPath == "/api/v1/uploads")
        if (uploading && (req.body?.contentLength() ?: 0) > 0) bodyUploads += "${req.method} ${req.url.encodedPath}"
        if (req.method != "PATCH") return chain.proceed(req)
        val n = synchronized(this) { ++patches }
        if (n != dropPatch) return chain.proceed(req)
        dropPatch = 0
        beforeDrop(req)
        val limit = dropAfterBytes
        // Nothing sent at all, but the connection is up: the outcome is unknown to the engine (R2).
        if (limit <= 0) throw IOException("chaos: connection dropped before the request")
        val body = req.body!!
        val failing =
            object : RequestBody() {
                override fun contentType(): MediaType? = body.contentType()

                override fun contentLength(): Long = body.contentLength()

                override fun isOneShot(): Boolean = true

                override fun writeTo(sink: BufferedSink) {
                    var sent = 0L
                    val counting =
                        object : ForwardingSink(sink) {
                            override fun write(
                                source: Buffer,
                                byteCount: Long,
                            ) {
                                val n2 = minOf(byteCount, limit - sent)
                                if (n2 > 0) {
                                    super.write(source, n2)
                                    sent += n2
                                }
                                if (sent >= limit) {
                                    sink.flush()
                                    throw IOException("chaos: connection dropped after $sent bytes")
                                }
                            }
                        }
                    counting.buffer().use { body.writeTo(it) }
                }
            }
        return chain.proceed(req.newBuilder().method("PATCH", failing).build())
    }
}

/**
 * The Android engine against a real `pictunnel` server (Task 8). Skipped
 * unless `PICTUNNEL_BIN` names a server binary (`task test:engine:android`).
 */
@RunWith(RobolectricTestRunner::class)
class ServerIntegrationTest {
    private lateinit var db: EngineDb
    private lateinit var store: FakeStore
    private val media = FakeMedia()
    private val clock = FakeClock()
    private val events = RecordingEvents()
    private val chaos = Chaos()
    private val random = Random(1)

    @Before fun setUp() {
        assumeTrue("PICTUNNEL_BIN is not set", server != null)
        db =
            Room
                .inMemoryDatabaseBuilder(ApplicationProvider.getApplicationContext(), EngineDb::class.java)
                .allowMainThreadQueries()
                .build()
        store = FakeStore(null)
        // Pair through the engine: the server's self-signed leaf is accepted only by its pin.
        val result = runBlocking { Pairer(store, CLIENT, "0.1.0").pair(server!!.pairingUri(), "IT Phone") }
        assertEquals("alice", result.userName)
        assertEquals(server!!.pin.trimEnd('='), store.creds!!.pinSpki.trimEnd('='))
    }

    @After fun tearDown() {
        if (::db.isInitialized) db.close()
    }

    private fun controller(): EngineController {
        val creds = store.creds!!
        val endpoints = Endpoints(creds.endpoints)
        val http =
            EngineHttp.newClient(
                creds.pinSpki,
                CLIENT,
                OkHttpClient.Builder().readTimeout(30, TimeUnit.SECONDS).addNetworkInterceptor(chaos).build(),
            )
        val auth = AuthManager(store, http, { clock.monotonicMs() }, CLIENT, endpoints)
        val client = ServerClient(endpoints, auth, http, CLIENT)
        return EngineController(db, FakeScanner(media), media, client, SettingsRepo(db.settings()), clock, events, EngineConfig())
    }

    private fun bytes(n: Int) = ByteArray(n).also { random.nextBytes(it) }

    private fun item(id: String) = runBlocking { db.items().get(id)!! }

    @Test fun uploadsAndDedupes() =
        runBlocking {
            val b = bytes(200_000)
            media.put("d1", b)
            media.put("d2", b)
            // The second row waits while the same bytes are in flight, then resolves without a body
            // (P§7.3 outcome #3): one run, one body upload, no failed attempt.
            val report = controller().runOnce(RunBudget())
            assertEquals(StopReason.Idle, report.stop)
            assertEquals(null, report.nextAttemptAtMs)
            assertEquals("exactly one body upload: ${chaos.lines}", 1, chaos.bodyUploads.size)
            assertEquals(ItemState.BackedUp, item("d1").state)
            assertEquals(ItemState.BackedUp, item("d2").state)
            assertEquals(0, item("d1").attempts + item("d2").attempts)
            assertEquals(item("d1").assetId, item("d2").assetId)
            assertEquals(1, server!!.assetsWithSha(sha(b)).size)
        }

    @Test fun dropMidPatchResumes() =
        runBlocking {
            val b = bytes(3 * 1024 * 1024 + 4321)
            media.put("big", b)
            chaos.dropPatch = 2
            chaos.dropAfterBytes = 300_000
            controller().runOnce(RunBudget())
            assertEquals(ItemState.BackedUp, item("big").state)
            assertTrue("resumed through HEAD: ${chaos.lines}", chaos.lines.any { it.startsWith("HEAD ") })
            assertEquals(1, chaos.lines.count { it == "POST /api/v1/uploads" })
            val assets = server!!.assetsWithSha(sha(b))
            assertEquals(1, assets.size)
            assertEquals(item("big").assetId, assets[0]["id"]!!.jsonPrimitive.content)
        }

    @Test fun resumesAfterSessionExpiry() =
        runBlocking {
            val b = bytes(2 * 1024 * 1024 + 99)
            media.put("exp", b)
            chaos.dropPatch = 2
            // No bytes reach the server, so it cannot answer the PATCH itself with 404.
            chaos.dropAfterBytes = 0
            // The session vanishes server-side (as on expiry) while the second chunk is in flight.
            var terminated = 0
            chaos.beforeDrop = { req ->
                // The session's lock may still be held from the previous PATCH: retry while locked.
                for (i in 0 until 50) {
                    terminated = server!!.local("DELETE", req.url.encodedPath).first
                    if (terminated != 423) break
                    Thread.sleep(100)
                }
            }
            controller().runOnce(RunBudget())
            assertEquals("tus termination", 204, terminated)
            assertEquals(ItemState.BackedUp, item("exp").state)
            val lines = chaos.lines.toList()
            val head = lines.indexOfFirst { it.startsWith("HEAD ") }
            assertTrue("HEAD after the drop: $lines", head > 0)
            assertEquals("a new session after the 404: $lines", 2, lines.count { it == "POST /api/v1/uploads" })
            assertTrue(lines.indexOfLast { it == "POST /api/v1/uploads" } > head)
            assertEquals(1, server!!.assetsWithSha(sha(b)).size)
        }

    @Test fun tombstoneSkipsThenUndo() =
        runBlocking {
            val b = bytes(50_000)
            val s = sha(b)
            media.put("t1", b)
            val c = controller()
            c.runOnce(RunBudget())
            val first = item("t1").assetId!!
            // Purge on the server: trash, then purge, which leaves a tombstone (P§7.7).
            assertEquals(200, server!!.local("POST", "/api/v1/assets/trash", """{"asset_ids":["$first"]}""").first)
            assertEquals(200, server!!.local("POST", "/api/v1/assets/purge", """{"asset_ids":["$first"]}""").first)

            media.put("t2", b)
            c.runOnce(RunBudget())
            assertEquals(ItemState.Skipped, item("t2").state)
            assertTrue(server!!.assetsWithSha(s).isEmpty())

            assertTrue(c.undoSkip(s))
            c.runOnce(RunBudget())
            assertEquals(ItemState.BackedUp, item("t2").state)
            val again = server!!.assetsWithSha(s)
            assertEquals(1, again.size)
            assertNotEquals(first, again[0]["id"]!!.jsonPrimitive.content)
            assertEquals(item("t2").assetId, again[0]["id"]!!.jsonPrimitive.content)
        }

    @Test fun refreshRotationSurvives() =
        runBlocking {
            val c = controller()
            val tokens = mutableListOf(store.creds!!.refreshToken)
            for (round in 1..3) {
                media.put("r$round", bytes(10_000 + round))
                // Past the access token's lifetime: the next request refreshes and rotates (P§6.2).
                clock.advance(15 * 60 * 1000L)
                c.runOnce(RunBudget())
                assertEquals(ItemState.BackedUp, item("r$round").state)
                tokens += store.creds!!.refreshToken
            }
            assertEquals("every refresh rotated the token: $tokens", tokens.size, tokens.distinct().size)
            assertEquals(0, store.wipes)
            assertEquals(0, events.repairs)
            // A restarted process starts from the stored (latest) token only.
            media.put("after-restart", bytes(777))
            controller().runOnce(RunBudget())
            assertEquals(ItemState.BackedUp, item("after-restart").state)
            assertEquals(0, store.wipes)
        }

    companion object {
        @Volatile private var server: RealServer? = null

        @JvmStatic @BeforeClass fun startServer() {
            val bin = System.getenv("PICTUNNEL_BIN")?.takeIf { it.isNotBlank() } ?: return
            server = RealServer.start(bin)
        }

        @JvmStatic @AfterClass fun stopServer() {
            server?.close()
            server = null
        }
    }
}
