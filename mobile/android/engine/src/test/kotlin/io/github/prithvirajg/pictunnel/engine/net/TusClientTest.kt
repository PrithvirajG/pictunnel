package io.github.prithvirajg.pictunnel.engine.net

import io.github.prithvirajg.pictunnel.engine.decide.Action
import io.github.prithvirajg.pictunnel.engine.decide.Decide
import io.github.prithvirajg.pictunnel.engine.decide.Given
import kotlinx.coroutines.runBlocking
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import okhttp3.OkHttpClient
import org.junit.jupiter.api.AfterEach
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertInstanceOf
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Test

class TusClientTest {
    private lateinit var server: MockWebServer

    @BeforeEach fun setUp() {
        server = MockWebServer()
        server.start()
    }

    @AfterEach fun tearDown() = server.close()

    private fun client(rest: (mockwebserver3.RecordedRequest) -> MockResponse): ServerClient {
        server.dispatcher = AuthingDispatcher(rest)
        val store = FakeStore(credsFor(server.base()))
        val endpoints = Endpoints(store.creds!!.endpoints)
        val http = EngineHttp.newClient(pin = null, clientHeader = CLIENT)
        val auth = AuthManager(store, http, { System.nanoTime() / 1_000_000 }, endpoints)
        return ServerClient(endpoints, auth, OkHttpClient(), CLIENT)
    }

    private val sha = "fbbab289f7f94b25736c58be46a994c441fd02552cc6022352e3d86d2fab7c83"

    @Test fun metadataEncoding() {
        // P§11.5 golden: sha256, filename IMG_0001.JPG, mime image/jpeg, local_id a-1.
        val meta = UploadMeta(sha256 = sha, filename = "IMG_0001.JPG", mime = "image/jpeg", localId = "a-1")
        assertEquals(
            "sha256 ZmJiYWIyODlmN2Y5NGIyNTczNmM1OGJlNDZhOTk0YzQ0MWZkMDI1NTJjYzYwMjIzNTJlM2Q4NmQyZmFiN2M4Mw==," +
                "filename SU1HXzAwMDEuSlBH,mime aW1hZ2UvanBlZw==,local_id YS0x",
            meta.encode(),
        )
        val full =
            UploadMeta(
                sha256 = "ab",
                filename = "é.mov",
                mime = "video/quicktime",
                pairRole = "live_video",
                pairSha256 = "cd",
                overrideTombstone = true,
            )
        assertEquals(
            "sha256 YWI=,filename w6kubW92,mime dmlkZW8vcXVpY2t0aW1l,pair_role bGl2ZV92aWRlbw==,pair_sha256 Y2Q=,override_tombstone MQ==",
            full.encode(),
        )
    }

    @Test fun createSingleShotFinalizes() =
        runBlocking {
            val bytes = ByteArray(1000) { it.toByte() }
            val api =
                client {
                    MockResponse
                        .Builder()
                        .code(201)
                        .addHeader("Tus-Resumable", "1.0.0")
                        .addHeader("Location", "/api/v1/uploads/01928f40-2222-7aaa-8bbb-0123456789ab")
                        .addHeader("Upload-Offset", "1000")
                        .addHeader("PicTunnel-Asset-Id", "01928f40-0000-7000-8000-000000000001")
                        .addHeader("PicTunnel-Asset-Created", "true")
                        .build()
                }
            val meta = UploadMeta(sha256 = sha, filename = "IMG_0001.JPG", mime = "image/jpeg")
            val out = api.tus.create(meta, 1000, UploadBody.of(bytes))
            val ok = assertInstanceOf(Outcome.Ok::class.java, out)
            val created = ok.value as TusCreated
            assertEquals(server.url("/api/v1/uploads/01928f40-2222-7aaa-8bbb-0123456789ab").toString(), created.url)
            assertEquals(1000L, created.offset)
            assertEquals("01928f40-0000-7000-8000-000000000001", created.assetId)
            assertEquals(true, created.assetCreated)
            // The engine's decide() maps it straight to BackedUp.
            val d = Decide.decide(Given("backup", "Uploading", "create_upload", mapOf("has_upload_id" to false)), ok.raw)
            assertEquals(Action.MARK_BACKED_UP, d.action)

            val req = drain(server).single { it.method == "POST" && it.url.encodedPath == "/api/v1/uploads" }
            assertEquals("1.0.0", req.headers["Tus-Resumable"])
            assertEquals("1000", req.headers["Upload-Length"])
            assertEquals("application/offset+octet-stream", req.headers["Content-Type"])
            assertEquals(meta.encode(), req.headers["Upload-Metadata"])
            assertEquals("Bearer pt_at_1", req.headers["Authorization"])
            assertEquals(bytes.toList(), req.body!!.toByteArray().toList())
        }

    @Test fun chunkedPatchSequence() =
        runBlocking {
            val bytes = ByteArray(20) { (it * 3).toByte() }
            val path = "/api/v1/uploads/01928f40-1111-7aaa-8bbb-0123456789ab"
            val api =
                client { r ->
                    when (r.method) {
                        "POST" ->
                            MockResponse
                                .Builder()
                                .code(201)
                                .addHeader("Location", path)
                                .addHeader("Upload-Expires", "Sun, 04 Oct 2026 12:00:00 GMT")
                                .build()
                        "PATCH" -> {
                            val off = r.headers["Upload-Offset"]!!.toLong() + r.bodySize
                            val b = MockResponse.Builder().code(204).addHeader("Upload-Offset", off.toString())
                            if (off == 20L) b.addHeader("PicTunnel-Asset-Id", "asset-1").addHeader("PicTunnel-Asset-Created", "true")
                            b.build()
                        }
                        else -> MockResponse.Builder().code(500).build()
                    }
                }
            val created =
                (api.tus.create(UploadMeta(sha, "v.mp4", "video/mp4"), 20, null) as Outcome.Ok).value
            assertEquals(0L, created.offset)
            assertEquals("Sun, 04 Oct 2026 12:00:00 GMT", created.expires)
            assertNull(created.assetId)

            val body = UploadBody.of(bytes)
            var offset = 0L
            var last: TusPatched? = null
            while (offset < 20) {
                val n = minOf(8L, 20 - offset)
                last = (api.tus.patch(created.url, offset, n, body) as Outcome.Ok).value
                assertEquals(offset + n, last.offset)
                offset = last.offset
            }
            assertEquals("asset-1", last!!.assetId)

            val reqs = drain(server).filter { it.url.encodedPath != "/api/v1/auth/refresh" }
            assertNull(reqs[0].body?.takeIf { it.size > 0 }, "bodyless creation")
            assertEquals("20", reqs[0].headers["Upload-Length"])
            val patches = reqs.drop(1)
            assertEquals(listOf("0", "8", "16"), patches.map { it.headers["Upload-Offset"] })
            assertEquals(listOf(8L, 8L, 4L), patches.map { it.bodySize })
            assertEquals(bytes.toList(), patches.flatMap { it.body!!.toByteArray().toList() })
            patches.forEach {
                assertEquals(path, it.url.encodedPath)
                assertEquals("1.0.0", it.headers["Tus-Resumable"])
                assertEquals("application/offset+octet-stream", it.headers["Content-Type"])
            }
        }

    @Test fun offsetMismatchReturnsServerOffset() =
        runBlocking {
            val api =
                client {
                    problem(409, "offset_mismatch").newBuilder().addHeader("Upload-Offset", "524288").build()
                }
            val out = api.tus.patch("/api/v1/uploads/x", 0, 4, UploadBody.of(ByteArray(4)))
            val fail = assertInstanceOf(Outcome.Fail::class.java, out)
            assertEquals(409, fail.raw.status)
            assertEquals(524288L, fail.raw.uploadOffset())
            assertEquals("offset_mismatch", fail.raw.problem()?.code)
            val d = Decide.decide(Given("backup", "Uploading", "append_upload", mapOf("has_upload_id" to true)), fail.raw)
            assertEquals(Action.HEAD_THEN_RESUME, d.action)
        }

    @Test fun headAndTerminate() =
        runBlocking {
            val api =
                client { r ->
                    when (r.method) {
                        "HEAD" ->
                            MockResponse
                                .Builder()
                                .code(200)
                                .addHeader("Upload-Offset", "524288")
                                .addHeader("Upload-Length", "1048576")
                                .addHeader("Upload-Expires", "Sun, 04 Oct 2026 12:00:00 GMT")
                                .build()
                        "DELETE" -> MockResponse.Builder().code(204).build()
                        else -> problem(404, "not_found")
                    }
                }
            val head = (api.tus.head(server.url("/api/v1/uploads/x").toString()) as Outcome.Ok).value
            assertEquals(TusHead(524288, 1048576, "Sun, 04 Oct 2026 12:00:00 GMT", null), head)
            assertInstanceOf(Outcome.Ok::class.java, api.tus.terminate("/api/v1/uploads/x"))
            val reqs = drain(server).filter { it.method != "POST" }
            assertEquals(listOf("HEAD", "DELETE"), reqs.map { it.method })
            reqs.forEach { assertEquals("/api/v1/uploads/x", it.url.encodedPath) }
        }
}
