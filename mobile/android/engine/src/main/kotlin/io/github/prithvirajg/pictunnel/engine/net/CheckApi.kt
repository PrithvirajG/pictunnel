package io.github.prithvirajg.pictunnel.engine.net

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonObject
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody

/** One content hash to ask about (P§7.2). [localId] links the device's item to an existing asset. */
data class CheckItem(
    val sha256: String,
    val sizeBytes: Long,
    val localId: String? = null,
)

/**
 * One check answer. [verdict] stays a string: unknown verdicts reach decide()
 * unchanged (R7). Unknown fields are ignored.
 */
@Serializable
data class CheckResult(
    val sha256: String,
    val verdict: String,
    @SerialName("asset_id") val assetId: String? = null,
    @SerialName("asset_state") val assetState: String? = null,
    @SerialName("has_live_video") val hasLiveVideo: Boolean? = null,
    @SerialName("on_disk") val onDisk: Boolean? = null,
    val upload: CheckUpload? = null,
    @SerialName("deleted_at") val deletedAt: String? = null,
)

/** The active session behind a `partial` verdict. [url] is as the server sent it (usually a path). */
@Serializable
data class CheckUpload(
    val id: String,
    val url: String,
    val offset: Long,
    val length: Long,
    @SerialName("expires_at") val expiresAt: String? = null,
)

/** `POST /api/v1/sync/check`: batches of 1 to 1000 items (R6). */
internal class CheckApi(
    private val client: ServerClient,
) {
    suspend fun check(
        items: List<CheckItem>,
        confirmOnDisk: Boolean,
    ): Outcome<List<CheckResult>> {
        require(items.size in 1..MAX_BATCH) { "check takes 1..$MAX_BATCH items, got ${items.size}" }
        val body =
            Problems.json.encodeToString(
                CheckRequest.serializer(),
                CheckRequest(items.map { CheckRequestItem(it.sha256, it.sizeBytes, it.localId, confirmOnDisk) }),
            )
        val raw =
            client.send(PATH, authenticated = true) { url ->
                Request.Builder().url(url).post(body.toRequestBody(JSON)).build()
            }
        if (raw.status != 200) return Outcome.Fail(raw)
        val parsed =
            runCatching {
                Problems.json.decodeFromJsonElement(CheckResponse.serializer(), raw.body ?: JsonObject(emptyMap())).results
            }.getOrNull() ?: return Outcome.Fail(raw)
        return Outcome.Ok(parsed, raw)
    }

    @Serializable
    private data class CheckRequest(
        val items: List<CheckRequestItem>,
    )

    @Serializable
    private data class CheckRequestItem(
        val sha256: String,
        @SerialName("size_bytes") val sizeBytes: Long,
        @SerialName("local_id") val localId: String?,
        @SerialName("confirm_on_disk") val confirmOnDisk: Boolean,
    )

    @Serializable
    private data class CheckResponse(
        val results: List<CheckResult>,
    )

    companion object {
        const val PATH = "/api/v1/sync/check"
        const val MAX_BATCH = 1000
        private val JSON = "application/json".toMediaType()
    }
}
