package io.github.prithvirajg.pictunnel.engine.net

import io.github.prithvirajg.pictunnel.engine.decide.Action
import io.github.prithvirajg.pictunnel.engine.decide.Decide
import io.github.prithvirajg.pictunnel.engine.decide.Given
import io.github.prithvirajg.pictunnel.engine.decide.ServerOutcome
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import okhttp3.OkHttpClient
import org.junit.jupiter.api.AfterEach
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertInstanceOf
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Test
import java.time.Instant

class ServerClientTest {
    private lateinit var server: MockWebServer

    @BeforeEach fun setUp() {
        server = MockWebServer()
        server.start()
    }

    @AfterEach fun tearDown() = server.close()

    private val serverInfo =
        """{"server_id":"01928f3e-7b2a-7c4d-9e1f-2a3b4c5d6e7f","name":"Home server","version":"0.1.0","api_version":"1.0",
 "min_client_version":{"android":"0.1.0","ios":"0.1.0","web":"0.1.0"},"capabilities":["tus"],
 "upload":{"tus_version":"1.0.0","max_file_bytes":53687091200,"recommended_chunk_bytes":8388608},
 "time":"2026-10-03T12:00:00Z","future_field":1}"""

    private val checkBody =
        """{"results":[
  {"sha256":"fbbab289","verdict":"exists","asset_id":"01928f40-0000-7000-8000-000000000001","asset_state":"active","has_live_video":false,"on_disk":true},
  {"sha256":"18af9b05","verdict":"missing"},
  {"sha256":"f6dd7fec","verdict":"partial","upload":{"id":"u1","url":"/api/v1/uploads/u1","offset":1048576,"length":3145728,"expires_at":"2026-10-04T12:00:00Z"}},
  {"sha256":"aaaa","verdict":"tombstoned","deleted_at":"2026-10-01T00:00:00Z"},
  {"sha256":"bbbb","verdict":"brand_new_verdict"}]}"""

    private fun stack(
        rest: (mockwebserver3.RecordedRequest) -> MockResponse,
        authHttp: OkHttpClient = EngineHttp.newClient(null, CLIENT),
    ): Pair<ServerClient, AuthingDispatcher> {
        val d = AuthingDispatcher(rest)
        server.dispatcher = d
        val store = FakeStore(credsFor(server.base()))
        val endpoints = Endpoints(store.creds!!.endpoints)
        val auth = AuthManager(store, authHttp, { 0L }, endpoints)
        return ServerClient(endpoints, auth, OkHttpClient(), CLIENT) to d
    }

    @Test fun clientHeaderOnEveryRequest() =
        runBlocking {
            var checks = 0
            val (api, d) =
                stack({ r ->
                    when {
                        r.url.encodedPath == "/api/v1/server/info" -> json(200, serverInfo)
                        r.url.encodedPath == "/api/v1/sync/check" ->
                            if (checks++ == 0) problem(401, "token_expired") else json(200, checkBody)
                        r.method == "POST" -> MockResponse.Builder().code(201).addHeader("Location", "/api/v1/uploads/u9").build()
                        r.method == "HEAD" -> MockResponse.Builder().code(200).addHeader("Upload-Offset", "0").build()
                        r.method == "PATCH" -> MockResponse.Builder().code(204).addHeader("Upload-Offset", "3").build()
                        else -> MockResponse.Builder().code(204).build()
                    }
                })
            val info = api.serverInfo()
            assertEquals(8388608L, info.upload.recommendedChunkBytes)
            assertEquals("0.1.0", info.minClientVersion["android"])

            val check = assertInstanceOf(Outcome.Ok::class.java, api.check(listOf(CheckItem("fbbab289", 3, "a-1")), confirmOnDisk = true))
            assertEquals(5, (check.value as List<*>).size)
            assertEquals(2, d.refreshes.get(), "initial token, then one refresh after the 401")

            val created = (api.tus.create(UploadMeta("aa", "a.jpg", "image/jpeg"), 3, null) as Outcome.Ok).value
            api.tus.head(created.url)
            api.tus.patch(created.url, 0, 3, UploadBody.of(byteArrayOf(1, 2, 3)))
            api.tus.terminate(created.url)

            val reqs = drain(server)
            assertEquals(
                listOf("GET", "POST", "POST", "POST", "POST", "POST", "HEAD", "PATCH", "DELETE"),
                reqs.map { it.method },
            )
            reqs.forEach { assertEquals(CLIENT, it.headers["PicTunnel-Client"], "${it.method} ${it.url}") }
            assertNull(reqs[0].headers["Authorization"], "server info is public")
            val checkReq = reqs.last { it.url.encodedPath == "/api/v1/sync/check" }
            assertEquals("Bearer pt_at_2", checkReq.headers["Authorization"])
            val item =
                kotlinx.serialization.json.Json
                    .parseToJsonElement(checkReq.body!!.utf8())
                    .jsonObject["items"]!!
                    .jsonArray[0]
                    .jsonObject
            assertEquals("a-1", item["local_id"]!!.jsonPrimitive.content)
            assertEquals("3", item["size_bytes"]!!.jsonPrimitive.content)
            assertEquals("true", item["confirm_on_disk"]!!.jsonPrimitive.content)
        }

    @Test fun checkParsesAllVerdicts() =
        runBlocking {
            val (api, _) = stack({ json(200, checkBody) })
            val results = (api.check(listOf(CheckItem("x", 1))) as Outcome.Ok).value
            assertEquals(listOf("exists", "missing", "partial", "tombstoned", "brand_new_verdict"), results.map { it.verdict })
            assertEquals("01928f40-0000-7000-8000-000000000001", results[0].assetId)
            assertEquals(true, results[0].onDisk)
            assertEquals(CheckUpload("u1", "/api/v1/uploads/u1", 1048576, 3145728, "2026-10-04T12:00:00Z"), results[2].upload)
            assertEquals("2026-10-01T00:00:00Z", results[3].deletedAt)
        }

    @Test fun retryAfterParsed() =
        runBlocking {
            val (api, _) = stack({ problem(429, "rate_limited").newBuilder().addHeader("Retry-After", "120").build() })
            val fail = assertInstanceOf(Outcome.Fail::class.java, api.check(listOf(CheckItem("x", 1))))
            assertEquals(429, fail.raw.status)
            assertEquals(120_000L, fail.raw.retryAfterMs())
            val p = fail.raw.problem()!!
            assertEquals("rate_limited", p.code)
            assertEquals("urn:pictunnel:problem:rate_limited", p.type)
            assertEquals(429, p.status)
            assertEquals(Action.WAIT_RETRY_AFTER, Decide.decide(Given("backup", "Hashed", "check", emptyMap()), fail.raw).action)

            val now = Instant.parse("2026-10-04T11:59:00Z").toEpochMilli()
            fun ra(v: String) = ServerOutcome(503, mapOf("retry-after" to v), null, null).retryAfterMs(now)
            assertEquals(60_000L, ra("Sun, 04 Oct 2026 12:00:00 GMT"))
            assertEquals(0L, ra("Sun, 04 Oct 2026 11:00:00 GMT"))
            assertEquals(0L, ra("0"))
            assertNull(ra("soon"))
            assertNull(ra("-5"))
            assertNull(ServerOutcome(503, emptyMap(), null, null).retryAfterMs(now))
        }

    @Test fun serverInfoFailureThrows() =
        runBlocking {
            val (api, _) = stack({ problem(503, "server_unavailable") })
            val e = runCatching { api.serverInfo() }.exceptionOrNull()
            val se = assertInstanceOf(ServerException::class.java, e)
            assertEquals(503, se.raw.status)
        }

    @Test fun nonJsonErrorBodyIsTolerated() =
        runBlocking {
            val (api, _) = stack({ MockResponse.Builder().code(502).body("<html>bad gateway</html>").build() })
            val fail = assertInstanceOf(Outcome.Fail::class.java, api.check(listOf(CheckItem("x", 1))))
            assertEquals(502, fail.raw.status)
            assertNull(fail.raw.body)
            assertNull(fail.raw.problem())
        }
}
