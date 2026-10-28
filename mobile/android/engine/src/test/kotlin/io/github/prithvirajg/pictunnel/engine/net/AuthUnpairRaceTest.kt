package io.github.prithvirajg.pictunnel.engine.net

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import mockwebserver3.Dispatcher
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import mockwebserver3.RecordedRequest
import org.junit.jupiter.api.AfterEach
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertInstanceOf
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertThrows
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

/** Review fix round 1: a refresh in flight while the phone unpairs (or re-pairs) never restores the old credentials. */
class AuthUnpairRaceTest {
    private lateinit var server: MockWebServer
    private val refreshArrived = CountDownLatch(1)
    private val releaseRefresh = CountDownLatch(1)
    private val refreshes = AtomicInteger()

    @BeforeEach fun setUp() {
        server = MockWebServer()
        server.dispatcher =
            object : Dispatcher() {
                override fun dispatch(request: RecordedRequest): MockResponse {
                    refreshes.incrementAndGet()
                    refreshArrived.countDown()
                    releaseRefresh.await(5, TimeUnit.SECONDS)
                    return json(200, tokens(1))
                }
            }
        server.start()
    }

    @AfterEach fun tearDown() = server.close()

    private fun auth(store: FakeStore) = AuthManager(store, EngineHttp.newClient(null, CLIENT), { System.nanoTime() / 1_000_000 }, CLIENT)

    @Test fun refreshInFlightDuringUnpairDoesNotRestoreCredentials() =
        runBlocking {
            val store = FakeStore(credsFor(server.base()))
            val auth = auth(store)
            val refresh = async(Dispatchers.IO) { runCatching { auth.accessToken() } }
            assertTrue(refreshArrived.await(5, TimeUnit.SECONDS))

            // Unpair: closes the session under the refresh lock, then wipes.
            val unpair = async(Dispatchers.IO) { auth.close { store.wipe() } }
            releaseRefresh.countDown()
            unpair.await()
            refresh.await()

            assertNull(store.creds, "the wipe ran after the refresh's save, so it wins")
            val e = assertThrows(AuthException::class.java) { runBlocking { auth.accessToken() } }
            assertInstanceOf(RefreshOutcome.NeedsRepair::class.java, e.outcome)
            assertEquals(1, refreshes.get(), "a closed session never refreshes again")
        }

    @Test fun aWipeThatBypassesTheLockIsNotUndoneByTheRefreshSave() =
        runBlocking {
            val store = FakeStore(credsFor(server.base()))
            val auth = auth(store)
            val refresh = async(Dispatchers.IO) { runCatching { auth.accessToken() } }
            assertTrue(refreshArrived.await(5, TimeUnit.SECONDS))
            store.wipe() // e.g. a keystore reset while the request is on the wire
            releaseRefresh.countDown()

            val e = refresh.await().exceptionOrNull()
            assertInstanceOf(AuthException::class.java, e)
            assertInstanceOf(RefreshOutcome.NeedsRepair::class.java, (e as AuthException).outcome)
            assertNull(store.creds, "compare-and-set refused the stale save")
            assertTrue(store.saved.isEmpty())
        }

    @Test fun aNewPairingDuringTheRefreshKeepsTheNewCredentials() =
        runBlocking {
            val store = FakeStore(credsFor(server.base()))
            val auth = auth(store)
            val refresh = async(Dispatchers.IO) { runCatching { auth.accessToken() } }
            assertTrue(refreshArrived.await(5, TimeUnit.SECONDS))
            val paired = credsFor(server.base()).copy(serverId = "other", refreshToken = "pt_rt_new")
            store.save(paired)
            releaseRefresh.countDown()
            refresh.await()
            assertEquals(paired, store.creds)
        }
}
