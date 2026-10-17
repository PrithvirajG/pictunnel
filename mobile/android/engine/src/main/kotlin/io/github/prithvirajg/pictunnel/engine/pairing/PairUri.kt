package io.github.prithvirajg.pictunnel.engine.pairing

import java.net.URI
import java.net.URISyntaxException
import java.net.URLDecoder
import java.security.MessageDigest

/** A parsed QR pairing payload (P§6.3). [endpoints] keep preference order, deduplicated. */
data class PairInfo(
    val serverId: String,
    val code: String,
    val fingerprint: String,
    val endpoints: List<String>,
)

sealed interface PairUriResult {
    data class Ok(
        val pair: PairInfo,
    ) : PairUriResult

    /** [code] is one of the P§10.3 error names, e.g. `invalid_code`. */
    data class Error(
        val code: String,
    ) : PairUriResult
}

/** Parses `pictunnel://pair?...` URIs and applies the pinning rule (P§6.3, P§10.3). */
object PairUri {
    private val CODE = Regex("^[0-9A-HJKMNP-TV-Z]{4}-[0-9A-HJKMNP-TV-Z]{4}-[0-9A-HJKMNP-TV-Z]{2}$")

    /** Errors are checked in the order P§10.3 lists them. */
    fun parse(uri: String): PairUriResult {
        val parsed =
            try {
                URI(uri)
            } catch (_: URISyntaxException) {
                return PairUriResult.Error("invalid_scheme")
            }
        if (parsed.scheme != "pictunnel" || parsed.host != "pair") return PairUriResult.Error("invalid_scheme")

        val params = query(parsed.rawQuery)
        fun first(k: String) = params.firstOrNull { it.first == k }?.second

        if (first("v") != "1") return PairUriResult.Error("unsupported_version")
        val sid = first("sid")
        if (sid.isNullOrEmpty()) return PairUriResult.Error("missing_server_id")
        val code = first("code")
        if (code == null || !CODE.matches(code)) return PairUriResult.Error("invalid_code")
        val fp = first("fp")
        if (fp.isNullOrEmpty()) return PairUriResult.Error("missing_fingerprint")
        val endpoints = params.filter { it.first == "u" && it.second.isNotEmpty() }.map { it.second }.distinct()
        if (endpoints.isEmpty()) return PairUriResult.Error("missing_endpoint")
        if (endpoints.any { !it.startsWith("https://") }) return PairUriResult.Error("insecure_endpoint")
        return PairUriResult.Ok(PairInfo(sid, code, fp, endpoints))
    }

    /**
     * Pinning rule: a chain the system trusts (and that matches the host) is
     * accepted; otherwise the leaf SPKI SHA-256 must equal [pin]. Both are
     * unpadded base64url; padding is ignored and the compare is constant-time.
     */
    fun acceptConnection(
        systemTrusted: Boolean,
        spkiSha256: String,
        pin: String,
    ): Boolean {
        if (systemTrusted) return true
        val a = spkiSha256.trimEnd('=').toByteArray(Charsets.US_ASCII)
        val b = pin.trimEnd('=').toByteArray(Charsets.US_ASCII)
        return a.isNotEmpty() && MessageDigest.isEqual(a, b)
    }

    private fun query(raw: String?): List<Pair<String, String>> =
        raw
            ?.split('&')
            ?.filter { it.isNotEmpty() }
            ?.map {
                val i = it.indexOf('=')
                val k = if (i < 0) it else it.substring(0, i)
                val v = if (i < 0) "" else it.substring(i + 1)
                decode(k) to decode(v)
            } ?: emptyList()

    private fun decode(s: String) = URLDecoder.decode(s, Charsets.UTF_8.name())
}
