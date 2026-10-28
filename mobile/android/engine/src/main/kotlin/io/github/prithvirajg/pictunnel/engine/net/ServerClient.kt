package io.github.prithvirajg.pictunnel.engine.net

import io.github.prithvirajg.pictunnel.engine.decide.ServerOutcome
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonObject
import okhttp3.HttpUrl
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.io.IOException

/** `GET /api/v1/server/info` (P§11.1). Unknown fields are ignored. */
@Serializable
data class ServerInfo(
    @SerialName("server_id") val serverId: String,
    val name: String? = null,
    val version: String? = null,
    @SerialName("api_version") val apiVersion: String? = null,
    @SerialName("min_client_version") val minClientVersion: Map<String, String> = emptyMap(),
    val capabilities: List<String> = emptyList(),
    val upload: UploadLimits = UploadLimits(),
    val time: String? = null,
)

@Serializable
data class UploadLimits(
    @SerialName("tus_version") val tusVersion: String = "1.0.0",
    @SerialName("max_file_bytes") val maxFileBytes: Long? = null,
    @SerialName("recommended_chunk_bytes") val recommendedChunkBytes: Long = DEFAULT_CHUNK_BYTES,
) {
    companion object {
        const val DEFAULT_CHUNK_BYTES = 8_388_608L
    }
}

/**
 * The engine's server API: every request carries `PicTunnel-Client:
 * [clientHeader]`, goes through [endpoints] (fallback and pinning live in
 * [http], built by [EngineHttp]), and authenticated requests carry the bearer
 * token from [auth]. A `401` (`unauthorized`/`token_expired`) triggers one
 * single-flight refresh and one retry (R11); anything else is returned raw for
 * decide().
 */
class ServerClient(
    private val endpoints: Endpoints,
    private val auth: AuthManager,
    http: OkHttpClient,
    clientHeader: String,
) {
    private val http: OkHttpClient = http.newBuilder().addInterceptor(ClientHeaderInterceptor(clientHeader)).build()
    private val checkApi = CheckApi(this)

    val tus: TusClient = TusClient(this)

    /** Public and exempt from the version gate (P§3). Throws [ServerException] on any failure. */
    suspend fun serverInfo(): ServerInfo {
        val raw = send(SERVER_INFO_PATH, authenticated = false) { Request.Builder().url(it).get().build() }
        if (raw.status != 200) throw ServerException(raw)
        return runCatching {
            Problems.json.decodeFromJsonElement(ServerInfo.serializer(), raw.body ?: JsonObject(emptyMap()))
        }.getOrElse { throw ServerException(raw) }
    }

    /** `POST /auth/logout`: revokes this device's session on the server. Returns the raw outcome. */
    suspend fun logout(): ServerOutcome =
        send(LOGOUT_PATH) { Request.Builder().url(it).post(ByteArray(0).toRequestBody(null)).build() }

    /** `POST /sync/check` for 1 to 1000 items; `confirmOnDisk` for free-up-space (P§7.8). */
    suspend fun check(
        items: List<CheckItem>,
        confirmOnDisk: Boolean = false,
    ): Outcome<List<CheckResult>> = checkApi.check(items, confirmOnDisk)

    /**
     * `DELETE /tombstones/{sha256}` ("back up again", P§7.7). Returns the raw
     * outcome; `204` removed it and `404` means there was none.
     */
    suspend fun deleteTombstone(sha256: String): ServerOutcome {
        require(sha256.matches(SHA256_HEX)) { "not a lowercase sha256: $sha256" }
        return send("$TOMBSTONES_PATH/$sha256") { Request.Builder().url(it).delete().build() }
    }

    /**
     * `GET /assets/{id}/original` streamed into [out] (saveToGallery). Throws
     * [ServerException] on a non-200 answer and [IOException] on transport
     * failures. A `401` refreshes once and retries, like [send].
     */
    suspend fun downloadOriginal(
        assetId: String,
        out: java.io.OutputStream,
    ) {
        require(assetId.isNotEmpty() && assetId.none { it == '/' || it == '?' || it == '#' }) { "bad asset id" }
        val path = "$ASSETS_PATH/$assetId/original"
        var token =
            try {
                auth.accessToken()
            } catch (e: AuthException) {
                throw ServerException(e.outcome.raw())
            }
        repeat(2) { attempt ->
            val response =
                endpoints.execute(http, path) { url ->
                    Request.Builder().url(url).get().header("Authorization", "Bearer $token").build()
                }
            response.use { r ->
                if (r.code == 200) {
                    kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) { r.body.byteStream().copyTo(out) }
                    return
                }
                val outcome = Problems.outcome(r)
                if (r.code != 401 || attempt == 1 || outcome.problem()?.code == "refresh_token_reused") throw ServerException(outcome)
                when (val refreshed = auth.onUnauthorized(token)) {
                    is RefreshOutcome.Refreshed -> token = refreshed.accessToken
                    else -> throw ServerException(refreshed.raw())
                }
            }
        }
    }

    /** Call on a network change: requests go back to the preferred (LAN-first) endpoint order (R9). */
    fun onNetworkChanged() = endpoints.resetToPreferred()

    /** The endpoint requests currently go to first. */
    val activeEndpoint: String get() = endpoints.active.toString()

    /**
     * Sends one request to [target] (a path or an absolute URL) and returns its
     * outcome; transport failures become transport outcomes. [build] must
     * create a fresh request (and body) each time: it runs again after a refresh.
     */
    internal suspend fun send(
        target: String,
        authenticated: Boolean = true,
        build: (HttpUrl) -> Request,
    ): ServerOutcome {
        if (!authenticated) return exchange(target, null, build)
        var token =
            try {
                auth.accessToken()
            } catch (e: AuthException) {
                return e.outcome.raw()
            }
        val first = exchange(target, token, build)
        if (first.status != 401 || first.problem()?.code == "refresh_token_reused") return first
        when (val r = auth.onUnauthorized(token)) {
            is RefreshOutcome.Refreshed -> token = r.accessToken
            else -> return r.raw()
        }
        return exchange(target, token, build)
    }

    /** A `Location` resolved against the active endpoint (the one that just answered). */
    internal fun resolveLocation(location: String): String? = endpoints.active.resolve(location)?.toString()

    private suspend fun exchange(
        target: String,
        token: String?,
        build: (HttpUrl) -> Request,
    ): ServerOutcome =
        try {
            Problems.outcome(
                endpoints.execute(http, target) { url ->
                    val req = build(url)
                    if (token == null) req else req.newBuilder().header("Authorization", "Bearer $token").build()
                },
            )
        } catch (e: IOException) {
            Problems.transport(e)
        }

    private fun RefreshOutcome.raw(): ServerOutcome =
        when (this) {
            is RefreshOutcome.Refreshed -> error("not a failure")
            is RefreshOutcome.NeedsRepair -> raw ?: AuthManager.NO_CREDENTIALS
            is RefreshOutcome.ClientTooOld -> raw
            // A refresh that "succeeded" with an unreadable body is an unknown outcome, never a 2xx here.
            is RefreshOutcome.Transient ->
                raw?.takeUnless { it.status in 200..299 } ?: ServerOutcome(null, emptyMap(), null, TRANSPORT_RESET)
        }

    companion object {
        const val SERVER_INFO_PATH = "/api/v1/server/info"
        const val LOGOUT_PATH = "/api/v1/auth/logout"
        const val TOMBSTONES_PATH = "/api/v1/tombstones"
        const val ASSETS_PATH = "/api/v1/assets"
        private val SHA256_HEX = Regex("^[0-9a-f]{64}$")
    }
}
