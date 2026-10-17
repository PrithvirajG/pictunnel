package io.github.prithvirajg.pictunnel.engine.net

import io.github.prithvirajg.pictunnel.engine.pairing.PairUri
import okhttp3.Interceptor
import okhttp3.OkHttpClient
import okhttp3.Response
import okhttp3.internal.tls.OkHostnameVerifier
import java.security.KeyStore
import java.security.MessageDigest
import java.security.cert.CertificateException
import java.security.cert.X509Certificate
import java.util.Base64
import javax.net.ssl.HostnameVerifier
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLSession
import javax.net.ssl.TrustManagerFactory
import javax.net.ssl.X509TrustManager

/**
 * The P§6.3 pinning rule as a trust manager: a chain the [system] store trusts
 * is accepted (the host is then checked by [PinningHostnameVerifier]);
 * otherwise the leaf's SPKI SHA-256 must equal [pin] (unpadded base64url,
 * padding ignored, constant-time compare). A rejection happens inside the TLS
 * handshake, so no request line, header or body is ever written.
 */
class PinningTrustManager(
    private val pin: String,
    private val system: X509TrustManager = systemDefault(),
) : X509TrustManager {
    override fun checkServerTrusted(
        chain: Array<out X509Certificate>,
        authType: String,
    ) {
        try {
            system.checkServerTrusted(chain, authType)
        } catch (e: CertificateException) {
            if (chain.isNotEmpty() && pinMatches(chain[0], pin)) return
            throw CertificateException("not trusted by the system and the SPKI pin does not match", e)
        }
    }

    override fun checkClientTrusted(
        chain: Array<out X509Certificate>,
        authType: String,
    ) = throw CertificateException("client certificates are not accepted")

    override fun getAcceptedIssuers(): Array<X509Certificate> = system.acceptedIssuers

    companion object {
        /** Unpadded base64url SHA-256 of the certificate's SubjectPublicKeyInfo (the pairing `fp`). */
        fun spkiSha256(cert: X509Certificate): String =
            Base64.getUrlEncoder().withoutPadding().encodeToString(
                MessageDigest.getInstance("SHA-256").digest(cert.publicKey.encoded),
            )

        fun pinMatches(
            leaf: X509Certificate,
            pin: String,
        ): Boolean = pin.isNotEmpty() && PairUri.acceptConnection(false, spkiSha256(leaf), pin)

        fun systemDefault(): X509TrustManager {
            val f = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm())
            f.init(null as KeyStore?)
            return f.trustManagers.filterIsInstance<X509TrustManager>().first()
        }
    }
}

/**
 * Accepts a pinned leaf for any host name (a self-signed server is commonly
 * reached by IP or `.local` name); everything else gets standard host checking.
 * Together with [PinningTrustManager]: accepted iff the pin matches, or the
 * system trusts the chain and it matches the host.
 */
class PinningHostnameVerifier(
    private val pin: String,
    private val fallback: HostnameVerifier = OkHostnameVerifier,
) : HostnameVerifier {
    override fun verify(
        hostname: String,
        session: SSLSession,
    ): Boolean {
        val leaf = runCatching { session.peerCertificates.firstOrNull() as? X509Certificate }.getOrNull()
        if (leaf != null && PinningTrustManager.pinMatches(leaf, pin)) return true
        return fallback.verify(hostname, session)
    }
}

/** Adds `PicTunnel-Client: <platform>/<version>` to every request (P§3 version gate). */
class ClientHeaderInterceptor(
    private val value: String,
) : Interceptor {
    override fun intercept(chain: Interceptor.Chain): Response =
        chain.proceed(chain.request().newBuilder().header(HEADER, value).build())

    companion object {
        const val HEADER = "PicTunnel-Client"
    }
}

/** Builds the engine's OkHttp client: client header, and pinning when a pin is stored. */
object EngineHttp {
    /**
     * [pin] null or empty means system trust only. [systemTrust] is injectable
     * for tests. The same client serves [AuthManager] and [ServerClient].
     */
    fun newClient(
        pin: String?,
        clientHeader: String,
        base: OkHttpClient = OkHttpClient(),
        systemTrust: X509TrustManager = PinningTrustManager.systemDefault(),
    ): OkHttpClient {
        val b = base.newBuilder().addInterceptor(ClientHeaderInterceptor(clientHeader))
        val tm = if (pin.isNullOrEmpty()) systemTrust else PinningTrustManager(pin, systemTrust)
        val ctx = SSLContext.getInstance("TLS").apply { init(null, arrayOf(tm), null) }
        b.sslSocketFactory(ctx.socketFactory, tm)
        if (!pin.isNullOrEmpty()) b.hostnameVerifier(PinningHostnameVerifier(pin))
        return b.build()
    }
}
