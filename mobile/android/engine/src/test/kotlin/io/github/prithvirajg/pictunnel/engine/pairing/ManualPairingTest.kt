package io.github.prithvirajg.pictunnel.engine.pairing

import io.github.prithvirajg.pictunnel.engine.net.CLIENT
import io.github.prithvirajg.pictunnel.engine.net.FakeStore
import io.github.prithvirajg.pictunnel.engine.net.PinningTrustManager
import io.github.prithvirajg.pictunnel.engine.net.json
import io.github.prithvirajg.pictunnel.engine.net.problem
import kotlinx.coroutines.runBlocking
import mockwebserver3.MockWebServer
import okhttp3.tls.HandshakeCertificates
import okhttp3.tls.HeldCertificate
import org.junit.jupiter.api.AfterEach
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertThrows
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Test

/** Manual setup (P§6.3 step 5): trust on first use, then a redeem pinned to the confirmed fingerprint. */
class ManualPairingTest {
    private lateinit var server: MockWebServer
    private val leaf = HeldCertificate.Builder().addSubjectAlternativeName("localhost").commonName("pictunnel").build()
    private val pin = PinningTrustManager.spkiSha256(leaf.certificate)

    @BeforeEach fun setUp() {
        server = MockWebServer()
        server.useHttps(HandshakeCertificates.Builder().heldCertificate(leaf).build().sslSocketFactory())
        server.start()
    }

    @AfterEach fun tearDown() = server.close()

    private fun origin() = server.url("/").toString().trimEnd('/')

    private val info = """{"server_id":"srv-1","name":"Home NAS","version":"1.0.0","api_version":"1"}"""

    private val redeemed =
        """{"server_id":"srv-1","user":{"username":"anna"},"device":{"id":"dev-1"},""" +
            """"tokens":{"access_token":"pt_at","refresh_token":"pt_rt_1"}}"""

    @Test fun probeReportsTheSelfSignedServersFingerprint() {
        server.enqueue(json(200, info))
        val fp = runBlocking { TrustOnFirstUse(CLIENT).probe(origin()) }
        assertEquals(pin, fp.fpFull)
        assertEquals(pin.take(16), fp.fp16)
        assertEquals("srv-1", fp.serverId)
        assertEquals("Home NAS", fp.name)
        assertEquals(origin(), fp.url)
        val r = server.takeRequest()
        assertEquals("/api/v1/server/info", r.url.encodedPath)
        assertEquals(CLIENT, r.headers["PicTunnel-Client"])
    }

    @Test fun probeOfSomethingElseIsNotPicTunnel() {
        server.enqueue(problem(404, "not_found"))
        val e = assertThrows(PairException::class.java) { runBlocking { TrustOnFirstUse(CLIENT).probe(origin()) } }
        assertEquals(TrustOnFirstUse.NOT_PICTUNNEL, e.code)
    }

    @Test fun aFailedHandshakeIsUnreachableNotAPinMismatch() {
        // The accept-any probe cannot have a pin mismatch: a handshake failure means the server is unreachable over TLS.
        val failing =
            okhttp3.OkHttpClient
                .Builder()
                .addInterceptor { throw javax.net.ssl.SSLHandshakeException("handshake_failure") }
                .build()
        val e = assertThrows(PairException::class.java) { runBlocking { TrustOnFirstUse(CLIENT, failing).probe(origin()) } }
        assertEquals("unreachable", e.code)
    }

    @Test fun manualPairPinsTheConfirmedFingerprint() {
        server.enqueue(json(200, redeemed))
        val store = FakeStore(null)
        val r = runBlocking { Pairer(store, CLIENT, "0.1.0").pairManual(origin(), "ABCD-EFGH-JK", pin, "Pixel") }
        assertEquals(PairResult("srv-1", "anna", "dev-1"), r)
        val c = store.creds!!
        assertEquals(listOf(origin()), c.endpoints)
        assertEquals(pin, c.pinSpki)
        assertEquals("pt_rt_1", c.refreshToken)
        val body = server.takeRequest().body!!.utf8()
        assertTrue(body.contains("\"code\":\"ABCD-EFGH-JK\"") && body.contains("\"device_name\":\"Pixel\""), body)
    }

    @Test fun aDifferentCertificateThanConfirmedIsAPinMismatch() {
        server.enqueue(json(200, redeemed))
        val store = FakeStore(null)
        val other = PinningTrustManager.spkiSha256(HeldCertificate.Builder().build().certificate)
        val e =
            assertThrows(PairException::class.java) {
                runBlocking { Pairer(store, CLIENT, "0.1.0").pairManual(origin(), "ABCD-EFGH-JK", other, "Pixel") }
            }
        assertEquals("tls", e.code)
        assertNull(store.creds)
    }

    @Test fun originsAreHttpsOnly() {
        assertEquals("https://nas.local:8443", TrustOnFirstUse.origin(" nas.local:8443/some/path "))
        assertEquals("https://nas.local", TrustOnFirstUse.origin("https://nas.local:443"))
        assertEquals("https://[fd00::1]:8443", TrustOnFirstUse.origin("https://[fd00::1]:8443"))
        assertEquals("insecure_endpoint", assertThrows(PairException::class.java) { TrustOnFirstUse.origin("http://nas.local") }.code)
        assertEquals("invalid_url", assertThrows(PairException::class.java) { TrustOnFirstUse.origin("https://") }.code)
    }
}
