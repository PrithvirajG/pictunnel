package io.github.prithvirajg.pictunnel.engine.net

import io.github.prithvirajg.pictunnel.engine.decide.ServerOutcome
import okhttp3.MediaType
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.Request
import okhttp3.RequestBody
import okhttp3.RequestBody.Companion.toRequestBody
import okio.Buffer
import okio.BufferedSink
import okio.Source
import okio.source
import java.io.File
import java.io.RandomAccessFile
import java.nio.channels.Channels
import java.util.Base64

/**
 * Upload bytes, reopenable at any offset: a 401 retry or a resumed upload
 * opens it again. [open] returns exactly [length] bytes starting at [offset].
 */
fun interface UploadBody {
    fun open(
        offset: Long,
        length: Long,
    ): Source

    companion object {
        fun of(bytes: ByteArray): UploadBody =
            UploadBody { offset, length ->
                require(offset >= 0 && length >= 0 && offset + length <= bytes.size) { "range out of bounds" }
                Buffer().write(bytes, offset.toInt(), length.toInt())
            }

        /** A seekable file (also the fallback copy for providers that cannot seek, M§5). */
        fun of(file: File): UploadBody =
            UploadBody { offset, _ ->
                val raf = RandomAccessFile(file, "r")
                try {
                    raf.seek(offset)
                    Channels.newInputStream(raf.channel).source()
                } catch (e: Throwable) {
                    raf.close()
                    throw e
                }
            }
    }
}

/**
 * tus `Upload-Metadata` (P§7.3). Keys are written in this order, each as
 * `key base64(value)` with standard padded base64 of the UTF-8 value, comma
 * separated; null values are left out.
 */
data class UploadMeta(
    val sha256: String,
    val filename: String,
    val mime: String,
    val localId: String? = null,
    val createdAt: String? = null,
    val modifiedAt: String? = null,
    val pairRole: String? = null,
    val pairSha256: String? = null,
    val stackKey: String? = null,
    val overrideTombstone: Boolean = false,
) {
    fun encode(): String {
        val b64 = Base64.getEncoder()
        return listOf(
            "sha256" to sha256,
            "filename" to filename,
            "mime" to mime,
            "local_id" to localId,
            "created_at" to createdAt,
            "modified_at" to modifiedAt,
            "pair_role" to pairRole,
            "pair_sha256" to pairSha256,
            "stack_key" to stackKey,
            "override_tombstone" to if (overrideTombstone) "1" else null,
        ).filter { it.second != null }
            .joinToString(",") { (k, v) -> "$k " + b64.encodeToString(v!!.toByteArray(Charsets.UTF_8)) }
    }
}

/**
 * A created (or joined, or already complete) upload. [url] is absolute,
 * resolved against the endpoint that answered. [assetId] is set when the
 * upload is complete: finalized by creation-with-upload, or content the
 * server already had (P§7.3 outcome 3).
 */
data class TusCreated(
    val url: String,
    val offset: Long,
    val expires: String?,
    val assetId: String?,
    val assetCreated: Boolean?,
)

data class TusHead(
    val offset: Long,
    val length: Long?,
    val expires: String?,
    val assetId: String?,
)

data class TusPatched(
    val offset: Long,
    val assetId: String?,
    val assetCreated: Boolean?,
)

/**
 * The tus 1.0.0 profile of P§7.3, hand-written over OkHttp. Every method
 * returns the raw outcome for decide(); none retries on its own. Upload URLs
 * may be absolute or paths (a check's `partial.upload.url`); either way they
 * go through [Endpoints] fallback when they belong to the server.
 */
class TusClient internal constructor(
    private val client: ServerClient,
) {
    /**
     * `POST /api/v1/uploads`. With [body] this is creation-with-upload of the
     * whole file ([length] bytes from offset 0, the Android single-shot
     * profile); without it the upload is created empty for PATCH chunks.
     */
    suspend fun create(
        meta: UploadMeta,
        length: Long,
        body: UploadBody?,
    ): Outcome<TusCreated> {
        val raw =
            client.send(PATH) { url ->
                Request
                    .Builder()
                    .url(url)
                    .tus()
                    .header("Upload-Length", length.toString())
                    .header("Upload-Metadata", meta.encode())
                    .post(body?.let { UploadRequestBody(it, 0, length) } ?: EMPTY)
                    .build()
            }
        if (raw.status != 201) return Outcome.Fail(raw)
        val location = raw.header("Location") ?: return Outcome.Fail(raw)
        val url = client.resolveLocation(location) ?: return Outcome.Fail(raw)
        return Outcome.Ok(
            TusCreated(
                url = url,
                offset = raw.uploadOffset() ?: 0,
                expires = raw.header("Upload-Expires"),
                assetId = raw.header(ASSET_ID),
                assetCreated = raw.assetCreated(),
            ),
            raw,
        )
    }

    /** `HEAD`: the session's offset; `404` means restart with POST. */
    suspend fun head(url: String): Outcome<TusHead> {
        val raw = client.send(url) { Request.Builder().url(it).tus().head().build() }
        if (raw.status != 200) return Outcome.Fail(raw)
        val offset = raw.uploadOffset() ?: return Outcome.Fail(raw)
        return Outcome.Ok(
            TusHead(offset, raw.header("Upload-Length")?.trim()?.toLongOrNull(), raw.header("Upload-Expires"), raw.header(ASSET_ID)),
            raw,
        )
    }

    /**
     * `PATCH` [length] bytes of [body] starting at [offset]. A wrong offset
     * fails with `409 offset_mismatch`; [ServerOutcome.uploadOffset] then holds
     * the server's offset. The completing PATCH carries the asset id.
     */
    suspend fun patch(
        url: String,
        offset: Long,
        length: Long,
        body: UploadBody,
    ): Outcome<TusPatched> {
        val raw =
            client.send(url) {
                Request
                    .Builder()
                    .url(it)
                    .tus()
                    .header("Upload-Offset", offset.toString())
                    .patch(UploadRequestBody(body, offset, length))
                    .build()
            }
        if (raw.status != 204 && raw.status != 200) return Outcome.Fail(raw)
        val newOffset = raw.uploadOffset() ?: return Outcome.Fail(raw)
        return Outcome.Ok(TusPatched(newOffset, raw.header(ASSET_ID), raw.assetCreated()), raw)
    }

    /** `DELETE` (tus termination). */
    suspend fun terminate(url: String): Outcome<Unit> {
        val raw = client.send(url) { Request.Builder().url(it).tus().delete().build() }
        return if (raw.status == 204 || raw.status == 200) Outcome.Ok(Unit, raw) else Outcome.Fail(raw)
    }

    private fun Request.Builder.tus() = header("Tus-Resumable", TUS_VERSION)

    private fun ServerOutcome.assetCreated(): Boolean? = header("PicTunnel-Asset-Created")?.trim()?.lowercase()?.toBooleanStrictOrNull()

    /**
     * Streams [length] bytes from [body] at [offset]. One-shot, so OkHttp never
     * silently re-sends upload bytes; an ambiguous failure goes to HEAD (R2).
     */
    private class UploadRequestBody(
        private val body: UploadBody,
        private val offset: Long,
        private val length: Long,
    ) : RequestBody() {
        override fun contentType(): MediaType = OCTET

        override fun contentLength(): Long = length

        override fun isOneShot(): Boolean = true

        override fun writeTo(sink: BufferedSink) {
            body.open(offset, length).use { sink.write(it, length) }
        }
    }

    companion object {
        const val PATH = "/api/v1/uploads"
        const val TUS_VERSION = "1.0.0"
        const val ASSET_ID = "PicTunnel-Asset-Id"
        private val OCTET = "application/offset+octet-stream".toMediaType()
        private val EMPTY = ByteArray(0).toRequestBody(null)
    }
}
