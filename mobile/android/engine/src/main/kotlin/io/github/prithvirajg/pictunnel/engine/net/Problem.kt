package io.github.prithvirajg.pictunnel.engine.net

import io.github.prithvirajg.pictunnel.engine.decide.ServerOutcome
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.intOrNull
import okhttp3.Response
import java.io.IOException
import java.net.SocketTimeoutException
import java.time.ZonedDateTime
import java.time.format.DateTimeFormatter
import javax.net.ssl.SSLException
import javax.net.ssl.SSLHandshakeException
import javax.net.ssl.SSLPeerUnverifiedException

/** The request timed out after the connection was up: the outcome is unknown (R2). */
const val TRANSPORT_TIMEOUT = "timeout"

/** The connection broke after it was up: the outcome is unknown (R2). */
const val TRANSPORT_RESET = "reset"

/** No endpoint could be reached; nothing was sent. Never counts as an attempt (R5). */
const val TRANSPORT_OFFLINE = "offline"

/**
 * TLS failed on every endpoint, most often a pin mismatch (P§6.3). Nothing was
 * sent. decide() treats it like any non-offline transport failure; the
 * controller should surface it as a connection-level problem.
 */
const val TRANSPORT_TLS = "tls"

/** The result of an engine call: a parsed value, or the raw outcome to hand to decide(). */
sealed interface Outcome<out T> {
    data class Ok<T>(
        val value: T,
        val raw: ServerOutcome,
    ) : Outcome<T>

    data class Fail(
        val raw: ServerOutcome,
    ) : Outcome<Nothing>
}

/** A non-success response where the caller needs a value, not an [Outcome] (server info). */
class ServerException(
    val raw: ServerOutcome,
) : IOException("server request failed: status=${raw.status} transport=${raw.transport} code=${raw.problem()?.code}")

/** An RFC 9457 problem body (P§3). [code] is the stable catalogue code (P§8). */
data class Problem(
    val code: String?,
    val type: String?,
    val title: String?,
    val status: Int?,
    val detail: String?,
    val requestId: String?,
)

object Problems {
    internal val json =
        Json {
            ignoreUnknownKeys = true
            explicitNulls = false
            encodeDefaults = true
        }

    /** Reads and closes [response]. A JSON body (including problem+json) is parsed; others are dropped. */
    fun outcome(response: Response): ServerOutcome =
        response.use { r ->
            val headers = LinkedHashMap<String, String>()
            for (name in r.headers.names()) headers[name] = r.headers.values(name).joinToString(", ")
            ServerOutcome(r.code, headers, parseBody(r), null)
        }

    /**
     * Maps an I/O failure to a transport outcome. `tls` only when nothing was
     * sent: every endpoint failed before a connection and at least one failed
     * its handshake, or a bare handshake/peer-verification failure. Any failure
     * after a connection was acquired ([AfterConnectException]), including a
     * later SSLException, is `timeout` or `reset`: the outcome is unknown (R2).
     */
    fun transport(e: IOException): ServerOutcome {
        val kind =
            when (e) {
                is EndpointsUnreachableException -> if (e.tls) TRANSPORT_TLS else TRANSPORT_OFFLINE
                is AfterConnectException -> if (e.cause is SocketTimeoutException) TRANSPORT_TIMEOUT else TRANSPORT_RESET
                is SSLHandshakeException, is SSLPeerUnverifiedException -> TRANSPORT_TLS
                is SocketTimeoutException -> TRANSPORT_TIMEOUT
                else -> TRANSPORT_RESET
            }
        return ServerOutcome(null, emptyMap(), null, kind)
    }

    private fun parseBody(r: Response): JsonElement? {
        val type = r.body.contentType()
        if (type == null || !type.subtype.contains("json", ignoreCase = true)) return null
        val text = r.body.string()
        if (text.isBlank()) return null
        return runCatching { Json.parseToJsonElement(text) }.getOrNull()
    }
}

/**
 * True when a TLS failure is anywhere in the chain. OkHttp's fast fallback
 * races IPv4 and IPv6 connects and may report a plain connect failure with the
 * TLS one only attached as suppressed.
 */
internal fun Throwable.involvesTls(depth: Int = 0): Boolean {
    if (this is SSLException) return true
    if (depth > 8) return false
    return cause?.involvesTls(depth + 1) == true || suppressed.any { it.involvesTls(depth + 1) }
}

/** The problem body, when the response carried one with a `code`, `type` or `title`. */
fun ServerOutcome.problem(): Problem? {
    val o = body as? JsonObject ?: return null
    fun s(k: String) = (o[k] as? JsonPrimitive)?.takeIf { it.isString }?.content
    if (s("code") == null && s("type") == null && s("title") == null) return null
    return Problem(s("code"), s("type"), s("title"), (o["status"] as? JsonPrimitive)?.intOrNull, s("detail"), s("request_id"))
}

/**
 * `Retry-After` in milliseconds from [nowMs]: delta-seconds (the server's form,
 * P§3) or an HTTP-date. Null when absent or unparseable; never negative.
 */
fun ServerOutcome.retryAfterMs(nowMs: Long = System.currentTimeMillis()): Long? {
    val v = header("Retry-After")?.trim() ?: return null
    if (v.isEmpty()) return null
    if (v.all { it.isDigit() }) return v.toLongOrNull()?.let { if (it > Long.MAX_VALUE / 1000) Long.MAX_VALUE else it * 1000 }
    val at =
        runCatching { ZonedDateTime.parse(v, DateTimeFormatter.RFC_1123_DATE_TIME).toInstant().toEpochMilli() }
            .getOrNull() ?: return null
    return (at - nowMs).coerceAtLeast(0)
}

/** The tus `Upload-Offset` header (HEAD, PATCH, and `409 offset_mismatch`). */
fun ServerOutcome.uploadOffset(): Long? = header("Upload-Offset")?.trim()?.toLongOrNull()
