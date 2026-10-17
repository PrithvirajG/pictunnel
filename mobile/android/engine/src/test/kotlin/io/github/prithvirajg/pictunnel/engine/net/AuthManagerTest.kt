package io.github.prithvirajg.pictunnel.engine.net

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.runBlocking
import mockwebserver3.Dispatcher
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import mockwebserver3.RecordedRequest
import org.junit.jupiter.api.AfterEach
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertInstanceOf
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Test
import java.util.concurrent.atomic.AtomicInteger

class AuthManagerTest {
    private lateinit var server: MockWebServer

    @BeforeEach fun setUp() {
        server = MockWebServer()
        server.start()
    }

    @AfterEach fun tearDown() = server.close()

    @Test fun refreshSingleFlight() =
        runBlocking {
            val refreshes = AtomicInteger()
            server.dispatcher =
                object : Dispatcher() {
                    override fun dispatch(request: RecordedRequest): MockResponse =
                        when (request.url.encodedPath) {
                            "/api/v1/auth/refresh" -> {
                                Thread.sleep(150) // keep the refresh in flight while the others pile up
                                json(200, tokens(refreshes.incrementAndGet()))
                            }
                            else ->
                                if (request.headers["Authorization"] == "Bearer pt_at_2") {
                                    json(200, """{"results":[{"sha256":"aa","verdict":"missing"}]}""")
                                } else {
                                    problem(401, "token_expired")
                                }
                        }
                }
            val store = FakeStore(credsFor(server.base()))
            val endpoints = Endpoints(store.creds!!.endpoints)
            val http = EngineHttp.newClient(null, CLIENT)
            val auth = AuthManager(store, http, { System.nanoTime() / 1_000_000 }, endpoints)
            val api = ServerClient(endpoints, auth, http, CLIENT)

            assertEquals("pt_at_1", auth.accessToken()) // warm: pt_at_1 is the token the server now rejects
            assertEquals(1, refreshes.get())

            val results =
                (1..10)
                    .map { async(Dispatchers.IO) { api.check(listOf(CheckItem("aa", 1))) } }
                    .awaitAll()

            assertEquals(2, refreshes.get(), "10 concurrent 401s cause exactly one refresh")
            results.forEach {
                val ok = assertInstanceOf(Outcome.Ok::class.java, it)
                assertEquals("missing", (ok.value as List<*>).filterIsInstance<CheckResult>().single().verdict)
            }
            assertEquals("pt_rt_2", store.creds!!.refreshToken, "the rotated refresh token is persisted")
            // The refresh body carried the stored token each time.
            val bodies =
                drain(server).filter { it.url.encodedPath == "/api/v1/auth/refresh" }.map { it.body!!.utf8() }
            assertEquals(listOf("""{"refresh_token":"pt_rt_0"}""", """{"refresh_token":"pt_rt_1"}"""), bodies)
        }

    @Test fun refreshReusedWipesCredentials() =
        runBlocking {
            server.dispatcher =
                object : Dispatcher() {
                    override fun dispatch(request: RecordedRequest) = problem(401, "refresh_token_reused")
                }
            val store = FakeStore(credsFor(server.base()))
            var repairs = 0
            val auth =
                AuthManager(store, EngineHttp.newClient(null, CLIENT), { 0L }, Endpoints(store.creds!!.endpoints))
            auth.onNeedsRepair = { repairs++ }

            val out = auth.onUnauthorized()
            val repair = assertInstanceOf(RefreshOutcome.NeedsRepair::class.java, out)
            assertEquals("refresh_token_reused", repair.raw?.problem()?.code)
            assertEquals(1, store.wipes)
            assertNull(store.creds)
            assertEquals(1, repairs)

            // The engine's requests now fail as require-repair without touching the network again.
            val before = server.requestCount
            val res = runCatching { auth.accessToken() }
            assertTrue(res.exceptionOrNull() is AuthException)
            assertEquals(before, server.requestCount)
        }

    @Test fun refreshNetworkFailureKeepsTokens() =
        runBlocking {
            val store = FakeStore(credsFor("http://127.0.0.1:1"))
            val auth = AuthManager(store, EngineHttp.newClient(null, CLIENT), { 0L })
            val out = auth.onUnauthorized()
            val t = assertInstanceOf(RefreshOutcome.Transient::class.java, out)
            assertEquals(TRANSPORT_OFFLINE, t.raw?.transport)
            assertEquals(0, store.wipes)
            assertEquals("pt_rt_0", store.creds!!.refreshToken)
        }
}
