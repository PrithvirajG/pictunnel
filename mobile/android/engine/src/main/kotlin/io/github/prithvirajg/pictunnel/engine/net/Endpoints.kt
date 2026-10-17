package io.github.prithvirajg.pictunnel.engine.net

import kotlinx.coroutines.suspendCancellableCoroutine
import okhttp3.Call
import okhttp3.Callback
import okhttp3.Connection
import okhttp3.EventListener
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import java.io.IOException
import java.util.concurrent.TimeUnit
import kotlin.coroutines.resumeWithException

/**
 * Every endpoint failed before a connection was established, so nothing was
 * sent. [tls] is true when at least one endpoint was reached but its TLS
 * handshake failed (for example a pin mismatch).
 */
class EndpointsUnreachableException(
    val tls: Boolean,
    cause: IOException,
) : IOException("no endpoint reachable", cause)

/**
 * The server's endpoints in stored preference order (R9: LAN first, then
 * remote). Requests go to the active endpoint first and fall back through the
 * others in stored order, but only for failures before a connection exists:
 * once a request may have reached the server, its failure is returned as is,
 * so an ambiguous upload is resolved by HEAD or check (R2), never re-sent
 * elsewhere. LAN endpoints use a 3 s connect timeout (M§4.4).
 *
 * The endpoint that answers becomes active; [resetToPreferred] returns to
 * stored order (call it on a network change).
 */
class Endpoints(
    urls: List<String>,
    private val lanConnectTimeoutMs: Long = LAN_CONNECT_TIMEOUT_MS,
) {
    val bases: List<HttpUrl> = urls.map { it.toHttpUrl() }

    @Volatile private var activeIndex = 0

    init {
        require(bases.isNotEmpty()) { "at least one endpoint is required" }
    }

    val active: HttpUrl get() = bases[activeIndex]

    fun resetToPreferred() {
        activeIndex = 0
    }

    /**
     * The path and query of [target] when it is a relative reference or an
     * absolute URL on one of the endpoints; null for a URL on another origin.
     */
    fun relativize(target: String): String? {
        if (target.startsWith("/")) return target
        val url = runCatching { target.toHttpUrl() }.getOrNull() ?: return null
        val known = bases.any { it.scheme == url.scheme && it.host == url.host && it.port == url.port }
        if (!known) return null
        return url.encodedPath + (url.encodedQuery?.let { "?$it" } ?: "")
    }

    /**
     * Sends a request built for [target] (a path such as `/api/v1/sync/check`,
     * or an absolute URL) with fallback across endpoints. A URL on an unknown
     * origin is sent as is, without fallback.
     */
    suspend fun execute(
        http: OkHttpClient,
        target: String,
        build: (HttpUrl) -> Request,
    ): Response {
        val path = relativize(target) ?: return http.newCall(build(target.toHttpUrl())).await()
        val start = activeIndex
        val order = listOf(start) + bases.indices.filter { it != start }
        var tls = false
        var last: IOException? = null
        for (i in order) {
            val base = bases[i]
            val tracker = ConnectTracker()
            val client =
                http
                    .newBuilder()
                    .eventListener(tracker)
                    .apply { if (isLan(base.host)) connectTimeout(lanConnectTimeoutMs, TimeUnit.MILLISECONDS) }
                    .build()
            try {
                val response = client.newCall(build(base.resolve(path)!!)).await()
                activeIndex = i
                return response
            } catch (e: IOException) {
                if (tracker.connected) throw e // the request may have reached the server
                if (e.involvesTls()) tls = true
                last = e
            }
        }
        throw EndpointsUnreachableException(tls, last!!)
    }

    /** Records whether the call got a connection; failures before that sent nothing. */
    private class ConnectTracker : EventListener() {
        @Volatile var connected = false

        override fun connectionAcquired(
            call: Call,
            connection: Connection,
        ) {
            connected = true
        }
    }

    companion object {
        const val LAN_CONNECT_TIMEOUT_MS = 3_000L

        /**
         * A host is LAN when it is a private, link-local or loopback IP literal,
         * an mDNS `.local` name, or a single-label name. No DNS lookup happens.
         */
        fun isLan(host: String): Boolean {
            val h = host.lowercase().trimEnd('.')
            if (h == "localhost" || h.endsWith(".local")) return true
            ipv4(h)?.let { (a, b) ->
                return a == 10 || a == 127 || (a == 172 && b in 16..31) || (a == 192 && b == 168) || (a == 169 && b == 254)
            }
            if (h.contains(':')) {
                return h == "::1" || h.startsWith("fe8") || h.startsWith("fe9") || h.startsWith("fea") ||
                    h.startsWith("feb") || h.startsWith("fc") || h.startsWith("fd")
            }
            return !h.contains('.')
        }

        private fun ipv4(h: String): Pair<Int, Int>? {
            val parts = h.split('.')
            if (parts.size != 4) return null
            val n = parts.map { p -> p.toIntOrNull()?.takeIf { it in 0..255 && p.isNotEmpty() } ?: return null }
            return n[0] to n[1]
        }
    }
}

/** Suspends until the call completes; cancelling the coroutine cancels the call. */
internal suspend fun Call.await(): Response =
    suspendCancellableCoroutine { cont ->
        cont.invokeOnCancellation { cancel() }
        enqueue(
            object : Callback {
                override fun onFailure(
                    call: Call,
                    e: IOException,
                ) {
                    cont.resumeWithException(e)
                }

                override fun onResponse(
                    call: Call,
                    response: Response,
                ) {
                    cont.resume(response) { _, value, _ -> value.close() }
                }
            },
        )
    }
