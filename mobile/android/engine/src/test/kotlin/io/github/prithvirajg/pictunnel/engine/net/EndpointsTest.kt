package io.github.prithvirajg.pictunnel.engine.net

import kotlinx.coroutines.runBlocking
import mockwebserver3.MockWebServer
import okhttp3.OkHttpClient
import okhttp3.Request
import org.junit.jupiter.api.AfterEach
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Test
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Socket
import java.net.SocketAddress
import java.net.SocketTimeoutException
import java.util.concurrent.CopyOnWriteArrayList
import javax.net.SocketFactory

class EndpointsTest {
    private lateinit var server: MockWebServer

    @BeforeEach fun setUp() {
        server = MockWebServer()
        server.start()
    }

    @AfterEach fun tearDown() = server.close()

    /** Simulates an unreachable LAN address: records the connect timeout and times out at once. */
    private class BlackholeLan(
        private val lanHost: String,
    ) : SocketFactory() {
        val lanTimeouts = CopyOnWriteArrayList<Int>()

        override fun createSocket(): Socket =
            object : Socket() {
                override fun connect(
                    endpoint: SocketAddress,
                    timeout: Int,
                ) {
                    if ((endpoint as InetSocketAddress).address.hostAddress == lanHost) {
                        lanTimeouts += timeout
                        throw SocketTimeoutException("connect timed out")
                    }
                    super.connect(endpoint, timeout)
                }
            }

        override fun createSocket(
            host: String?,
            port: Int,
        ): Socket = throw UnsupportedOperationException()

        override fun createSocket(
            host: String?,
            port: Int,
            localHost: InetAddress?,
            localPort: Int,
        ): Socket = throw UnsupportedOperationException()

        override fun createSocket(
            host: InetAddress?,
            port: Int,
        ): Socket = throw UnsupportedOperationException()

        override fun createSocket(
            address: InetAddress?,
            port: Int,
            localAddress: InetAddress?,
            localPort: Int,
        ): Socket = throw UnsupportedOperationException()
    }

    @Test fun endpointFallbackLanThenRemote() =
        runBlocking {
            server.enqueue(json(200, "{}"))
            server.enqueue(json(200, "{}"))
            val remote = "http://127.0.0.1:${server.port}"
            val endpoints = Endpoints(listOf("https://192.168.77.1:8443", remote))
            assertEquals("192.168.77.1", endpoints.active.host, "LAN is preferred first")
            val sockets = BlackholeLan("192.168.77.1")
            val http = OkHttpClient.Builder().socketFactory(sockets).build()

            val first = endpoints.execute(http, "/api/v1/server/info") { Request.Builder().url(it).build() }
            first.use { assertEquals(200, it.code) }
            assertTrue(sockets.lanTimeouts.isNotEmpty())
            sockets.lanTimeouts.forEach { assertEquals(3000, it, "LAN connect timeout is 3 s") }
            assertEquals(server.port, endpoints.active.port, "the remote endpoint is now active")
            assertEquals("/api/v1/server/info", server.takeRequest().url.encodedPath)

            // The next request goes straight to the active endpoint.
            val tries = sockets.lanTimeouts.size
            endpoints.execute(http, "/api/v1/server/info") { Request.Builder().url(it).build() }.close()
            assertEquals(tries, sockets.lanTimeouts.size)

            // Back to stored order after a network change.
            endpoints.resetToPreferred()
            assertEquals("192.168.77.1", endpoints.active.host)
        }

    @Test fun allUnreachableIsOffline() =
        runBlocking {
            val endpoints = Endpoints(listOf("http://127.0.0.1:1", "http://127.0.0.1:2"))
            val e =
                runCatching {
                    endpoints.execute(OkHttpClient(), "/x") { Request.Builder().url(it).build() }
                }.exceptionOrNull()
            assertTrue(e is java.io.IOException)
            assertEquals(TRANSPORT_OFFLINE, Problems.transport(e as java.io.IOException).transport)
        }

    @Test fun lanClassification() {
        listOf("192.168.1.10", "10.0.0.2", "172.20.1.1", "169.254.3.4", "nas.local", "nas", "[fd00::1]", "[fe80::1]")
            .forEach { assertTrue(Endpoints.isLan(okhttp3.HttpUrl.Builder().scheme("https").host(it.trim('[', ']')).build().host), it) }
        listOf("photos.example.com", "8.8.8.8", "172.32.0.1", "[2001:db8::1]")
            .forEach { assertFalse(Endpoints.isLan(okhttp3.HttpUrl.Builder().scheme("https").host(it.trim('[', ']')).build().host), it) }
    }

    @Test fun relativeAndAbsoluteTargets() {
        val endpoints = Endpoints(listOf("https://192.168.1.10:8443", "https://photos.example.com"))
        assertEquals("/api/v1/uploads/x", endpoints.relativize("https://photos.example.com/api/v1/uploads/x"))
        assertEquals("/api/v1/uploads/x?a=1", endpoints.relativize("https://192.168.1.10:8443/api/v1/uploads/x?a=1"))
        assertEquals("/api/v1/uploads/x", endpoints.relativize("/api/v1/uploads/x"))
        assertEquals(null, endpoints.relativize("https://elsewhere.example/api/v1/uploads/x"))
    }
}
