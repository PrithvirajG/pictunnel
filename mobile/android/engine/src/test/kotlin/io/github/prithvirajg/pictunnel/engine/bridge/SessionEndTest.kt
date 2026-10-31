package io.github.prithvirajg.pictunnel.engine.bridge

import android.content.Context
import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import androidx.work.Configuration
import androidx.work.testing.SynchronousExecutor
import androidx.work.testing.WorkManagerTestInitHelper
import io.github.prithvirajg.pictunnel.engine.net.FakeStore
import io.github.prithvirajg.pictunnel.engine.net.base
import io.github.prithvirajg.pictunnel.engine.net.credsFor
import io.github.prithvirajg.pictunnel.engine.net.drain
import io.github.prithvirajg.pictunnel.engine.net.json
import io.github.prithvirajg.pictunnel.engine.net.tokens
import io.github.prithvirajg.pictunnel.engine.store.EngineDb
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import mockwebserver3.Dispatcher
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import mockwebserver3.RecordedRequest
import org.junit.After
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** Review fix round 2: no session is rebuilt from credentials that are being wiped. */
@RunWith(RobolectricTestRunner::class)
class SessionEndTest {
    private val context: Context get() = ApplicationProvider.getApplicationContext()
    private lateinit var server: MockWebServer
    private lateinit var db: EngineDb
    private val refreshArrived = CountDownLatch(1)
    private val releaseRefresh = CountDownLatch(1)

    @Volatile private var holdRefresh = true

    @Before fun setUp() {
        WorkManagerTestInitHelper.initializeTestWorkManager(context, Configuration.Builder().setExecutor(SynchronousExecutor()).build())
        server = MockWebServer()
        server.dispatcher =
            object : Dispatcher() {
                override fun dispatch(request: RecordedRequest): MockResponse =
                    when (request.url.encodedPath) {
                        "/api/v1/auth/refresh" -> {
                            refreshArrived.countDown()
                            if (holdRefresh) releaseRefresh.await(10, TimeUnit.SECONDS)
                            json(200, tokens(1))
                        }
                        "/api/v1/auth/logout" -> MockResponse.Builder().code(204).build()
                        else -> json(404, "{}")
                    }
            }
        server.start()
        db = Room.inMemoryDatabaseBuilder(context, EngineDb::class.java).allowMainThreadQueries().build()
    }

    @After fun tearDown() {
        releaseRefresh.countDown()
        db.close()
        server.close()
    }

    @Test fun aSessionRequestedDuringASlowCloseIsNotCachedAfterTheWipe() =
        runBlocking {
            val store = FakeStore(credsFor(server.base()))
            val services = EngineServices(context, db, store)
            val old = services.session()!!
            // A refresh is in flight (it holds the refresh lock and cannot be cancelled).
            val refresh = async(Dispatchers.IO) { runCatching { old.auth.accessToken() } }
            assertTrue(refreshArrived.await(5, TimeUnit.SECONDS))

            val end = async(Dispatchers.IO) { services.endSession { store.wipe() } }
            // While the close waits for the refresh, getStatus or the network callback asks for the session.
            val deadline = System.currentTimeMillis() + 5_000
            while (services.session() != null) {
                assertTrue("session() kept returning a session while ending", System.currentTimeMillis() < deadline)
                Thread.sleep(10)
            }
            assertTrue("still waiting for the refresh", !end.isCompleted)

            releaseRefresh.countDown()
            end.await()
            refresh.await()
            assertNull(store.creds)
            assertNull("nothing built from the old credentials survived the wipe", services.session())
        }

    @Test fun connectionIsNullAfterUnpair() =
        runBlocking {
            holdRefresh = false
            val store = FakeStore(credsFor(server.base()))
            val services = EngineServices(context, db, store)
            val backend = AndroidHostBackend(context, services) { null }
            assertNotNull(backend.connection())

            backend.unpair()

            assertNull(store.creds)
            assertNull(backend.connection())
            val paths = drain(server).map { it.url.encodedPath }
            assertTrue("best-effort logout was sent: $paths", "/api/v1/auth/logout" in paths)
        }
}
