package io.github.prithvirajg.pictunnel.engine.pairing

import io.github.prithvirajg.pictunnel.engine.net.ClientHeaderInterceptor
import io.github.prithvirajg.pictunnel.engine.net.PinningTrustManager
import io.github.prithvirajg.pictunnel.engine.net.Problems
import io.github.prithvirajg.pictunnel.engine.net.ServerInfo
import io.github.prithvirajg.pictunnel.engine.net.involvesTls
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.IOException
import java.security.cert.X509Certificate
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import javax.net.ssl.SSLContext
import javax.net.ssl.X509TrustManager

/** A server as manual setup shows it before pairing: the user compares [fp16] with the server's admin page. */
data class ServerFingerprint(
    val serverId: String,
    val name: String,
    /** Unpadded base64url SHA-256 of the leaf certificate's SubjectPublicKeyInfo (the QR `fp`). */
    val fpFull: String,
    /** The origin pairing will use, e.g. `https://192.168.1.20:8443`. */
    val url: String,
) {
    /** The first 16 characters, as the server's mDNS TXT `fp16` and admin page show it. */
    val fp16: String get() = fpFull.take(16)
}

/**
 * Trust on first use for manual setup (P§6.3 step 5): one public
 * `GET /api/v1/server/info` that accepts whatever certificate the server
 * presents and reports its SPKI fingerprint. Nothing secret is sent; the
 * connection is trusted only later, by pinning the fingerprint the user
 * confirmed ([Pairer.pairManual]). Errors are [PairException]s: a transport
 * kind (`offline`, `timeout`, `reset`), `unreachable` (including a failed
 * handshake), `insecure_endpoint`, `invalid_url` or
 * `not_pictunnel`.
 */
class TrustOnFirstUse(
    private val clientHeader: String,
    private val base: OkHttpClient = OkHttpClient(),
) {
    suspend fun probe(serverUrl: String): ServerFingerprint {
        val origin = origin(serverUrl)
        val leaf = AtomicReference<X509Certificate?>()
        val capture =
            object : X509TrustManager {
                override fun checkClientTrusted(
                    chain: Array<out X509Certificate>,
                    authType: String,
                ) = throw java.security.cert.CertificateException("client certificates are not accepted")

                override fun checkServerTrusted(
                    chain: Array<out X509Certificate>,
                    authType: String,
                ) {
                    leaf.set(chain.firstOrNull())
                }

                override fun getAcceptedIssuers(): Array<X509Certificate> = emptyArray()
            }
        val ctx = SSLContext.getInstance("TLS").apply { init(null, arrayOf(capture), null) }
        val http =
            base
                .newBuilder()
                .sslSocketFactory(ctx.socketFactory, capture)
                .hostnameVerifier { _, _ -> true }
                .addInterceptor(ClientHeaderInterceptor(clientHeader))
                .followRedirects(false)
                .followSslRedirects(false)
                .callTimeout(TIMEOUT_S, TimeUnit.SECONDS)
                .build()
        val request = Request.Builder().url("$origin$INFO_PATH").get().build()
        val (code, body) =
            try {
                withContext(Dispatchers.IO) {
                    http.newCall(request).execute().use { r -> r.code to r.body.string() }
                }
            } catch (e: IOException) {
                // This probe accepts any certificate, so a failed handshake is not a pin
                // mismatch: the server could not be reached over TLS.
                val kind = Problems.transport(e).transport
                throw PairException(if (kind == null || kind == "tls" || e.involvesTls()) UNREACHABLE else kind)
            }
        val info =
            if (code == 200) runCatching { JSON.decodeFromString(ServerInfo.serializer(), body) }.getOrNull() else null
        if (info == null) throw PairException(NOT_PICTUNNEL)
        val cert = leaf.get() ?: throw PairException(NOT_PICTUNNEL)
        return ServerFingerprint(info.serverId, info.name ?: "PicTunnel", PinningTrustManager.spkiSha256(cert), origin)
    }

    companion object {
        const val NOT_PICTUNNEL = "not_pictunnel"
        const val UNREACHABLE = "unreachable"
        private const val INFO_PATH = "/api/v1/server/info"
        private const val TIMEOUT_S = 10L
        private val JSON = Json { ignoreUnknownKeys = true }

        /** `https://host[:port]` of [serverUrl]; pairing stores origins only (P§6.3 `u`). */
        fun origin(serverUrl: String): String {
            val t = serverUrl.trim()
            if (t.startsWith("http://", ignoreCase = true)) throw PairException("insecure_endpoint")
            val url = (if (t.contains("://")) t else "https://$t").toHttpUrlOrNull() ?: throw PairException("invalid_url")
            if (!url.isHttps) throw PairException("insecure_endpoint")
            val host = if (url.host.contains(':')) "[${url.host}]" else url.host
            return if (url.port == 443) "https://$host" else "https://$host:${url.port}"
        }
    }
}
