package io.github.prithvirajg.pictunnel.engine.net

import kotlinx.coroutines.runBlocking
import mockwebserver3.MockWebServer
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.tls.HandshakeCertificates
import okhttp3.tls.HeldCertificate
import okio.Buffer
import org.junit.jupiter.api.AfterEach
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertInstanceOf
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Test
import java.security.MessageDigest
import java.util.Base64
import java.util.concurrent.atomic.AtomicInteger
import javax.net.ssl.X509TrustManager

class PinningTest {
    private lateinit var server: MockWebServer

    @BeforeEach fun setUp() {
        server = MockWebServer()
        server.start()
    }

    @AfterEach fun tearDown() = server.close()

    private val root = HeldCertificate.Builder().certificateAuthority(0).commonName("PicTunnel Test Root").build()

    /** The "system" trust store for these tests: it trusts [root] only. */
    private val system: X509TrustManager =
        HandshakeCertificates.Builder().addTrustedCertificate(root.certificate).build().trustManager

    private fun serve(
        leaf: HeldCertificate,
        vararg chain: java.security.cert.X509Certificate,
    ) {
        server.useHttps(HandshakeCertificates.Builder().heldCertificate(leaf, *chain).build().sslSocketFactory())
    }

    private fun spki(c: HeldCertificate) =
        Base64.getUrlEncoder().withoutPadding().encodeToString(
            MessageDigest.getInstance("SHA-256").digest(c.certificate.publicKey.encoded),
        )

    private fun get(http: OkHttpClient) = http.newCall(Request.Builder().url(server.url("/api/v1/server/info")).build()).execute()

    @Test fun spkiMatchesPairingFingerprintFormat() {
        val c = HeldCertificate.Builder().build()
        assertEquals(spki(c), PinningTrustManager.spkiSha256(c.certificate))
        assertEquals(43, spki(c).length)
    }

    @Test fun acceptsSystemTrusted() {
        val leaf =
            HeldCertificate
                .Builder()
                .addSubjectAlternativeName(server.hostName)
                .addSubjectAlternativeName("localhost")
                .addSubjectAlternativeName("127.0.0.1")
                .signedBy(root)
                .build()
        serve(leaf, root.certificate)
        server.enqueue(json(200, "{}"))
        // The pin is unrelated: a system-trusted chain matching the host wins.
        val other = HeldCertificate.Builder().build()
        val http = EngineHttp.newClient(pin = spki(other), clientHeader = CLIENT, systemTrust = system)
        get(http).use { assertEquals(200, it.code) }
    }

    @Test fun rejectsSystemTrustedWrongHostWithoutPin() {
        val leaf = HeldCertificate.Builder().addSubjectAlternativeName("other.example").signedBy(root).build()
        serve(leaf, root.certificate)
        server.enqueue(json(200, "{}"))
        val http = EngineHttp.newClient(pin = spki(HeldCertificate.Builder().build()), clientHeader = CLIENT, systemTrust = system)
        val e = runCatching { get(http).close() }.exceptionOrNull()
        assertTrue(e is java.io.IOException && e.involvesTls(), e.toString())
    }

    @Test fun acceptsPinnedSelfSigned() {
        // Self-signed, not system trusted, and not even for this host: the SPKI pin decides.
        val self = HeldCertificate.Builder().addSubjectAlternativeName("pictunnel.invalid").build()
        serve(self)
        server.enqueue(json(200, "{}"))
        val http = EngineHttp.newClient(pin = spki(self), clientHeader = CLIENT, systemTrust = system)
        get(http).use { assertEquals(200, it.code) }
        // Padding on the stored pin is ignored.
        server.enqueue(json(200, "{}"))
        val padded = EngineHttp.newClient(pin = spki(self) + "=", clientHeader = CLIENT, systemTrust = system)
        get(padded).use { assertEquals(200, it.code) }
    }

    @Test fun rejectsChangedPin() =
        runBlocking {
            val now = HeldCertificate.Builder().addSubjectAlternativeName("localhost").build()
            val pinned = HeldCertificate.Builder().addSubjectAlternativeName("localhost").build()
            serve(now)
            server.enqueue(json(201, "{}"))

            val store = FakeStore(credsFor(server.base()).copy(pinSpki = spki(pinned)))
            val http = EngineHttp.newClient(pin = store.creds!!.pinSpki, clientHeader = CLIENT, systemTrust = system)
            val endpoints = Endpoints(store.creds!!.endpoints)
            val auth = AuthManager(store, http, { 0L }, CLIENT, endpoints)
            val api = ServerClient(endpoints, auth, http, CLIENT)

            val opened = AtomicInteger()
            val body =
                UploadBody { _, length ->
                    opened.incrementAndGet()
                    Buffer().write(ByteArray(length.toInt()))
                }
            val out = api.tus.create(UploadMeta("aa", "a.jpg", "image/jpeg"), 16, body)
            val fail = assertInstanceOf(Outcome.Fail::class.java, out)
            assertEquals(TRANSPORT_TLS, fail.raw.transport)
            assertEquals(null, fail.raw.status)
            assertEquals(0, opened.get(), "no upload body is ever produced")
            // Nothing reached the HTTP layer: neither the refresh token nor any request body.
            drain(server).forEach { assertEquals(0L, it.bodySize.coerceAtLeast(0L)) }
            assertEquals("pt_rt_0", store.creds!!.refreshToken)
        }

    @Test fun rejectsPinOfIssuingCa() =
        runBlocking {
            // The pin names the leaf's key; pinning the (untrusted) CA must not accept its leaves.
            val ca = HeldCertificate.Builder().certificateAuthority(0).build()
            val leaf = HeldCertificate.Builder().addSubjectAlternativeName("localhost").signedBy(ca).build()
            serve(leaf, ca.certificate)
            server.enqueue(json(200, "{}"))
            val http = EngineHttp.newClient(pin = spki(ca), clientHeader = CLIENT, systemTrust = system)
            val e = runCatching { get(http).close() }.exceptionOrNull()
            assertTrue(e is java.io.IOException && e.involvesTls(), e.toString())
            val endpoints = Endpoints(listOf(server.base()))
            val e2 =
                runCatching { endpoints.execute(http, "/api/v1/server/info") { Request.Builder().url(it).build() } }
                    .exceptionOrNull() as java.io.IOException
            assertEquals(TRANSPORT_TLS, Problems.transport(e2).transport)
        }
}
