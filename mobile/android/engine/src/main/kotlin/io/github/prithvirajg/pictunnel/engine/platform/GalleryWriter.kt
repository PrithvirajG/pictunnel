package io.github.prithvirajg.pictunnel.engine.platform

import android.content.ContentUris
import android.content.ContentValues
import android.content.Context
import android.provider.MediaStore
import io.github.prithvirajg.pictunnel.engine.net.ServerClient
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.IOException
import java.io.OutputStream

/** Writes an asset's original bytes to [out]; throws on any failure. */
fun interface OriginalDownloader {
    suspend fun download(
        assetId: String,
        out: OutputStream,
    )
}

/**
 * `saveToGallery` (M§3): downloads an original from the server into the phone
 * gallery. The row is inserted with `IS_PENDING = 1`, so no other app (and no
 * scan) sees a half-written file, then published. A failed download removes
 * the row. Returns the new item's local id; the next scan indexes it and check
 * finds it already backed up.
 */
class GalleryWriter(
    context: Context,
    private val downloader: OriginalDownloader,
) {
    private val resolver = context.contentResolver

    constructor(context: Context, client: ServerClient) : this(context, OriginalDownloader { id, out -> client.downloadOriginal(id, out) })

    suspend fun saveToGallery(
        assetId: String,
        filename: String,
        mime: String,
    ): String {
        val type =
            when {
                mime.startsWith("image/") -> LocalIds.IMAGE
                mime.startsWith("video/") -> LocalIds.VIDEO
                else -> throw IllegalArgumentException("not a photo or video: $mime")
            }
        val volume = MediaStore.VOLUME_EXTERNAL_PRIMARY
        val values =
            ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, filename)
                put(MediaStore.MediaColumns.MIME_TYPE, mime)
                put(MediaStore.MediaColumns.RELATIVE_PATH, RELATIVE_PATH)
                put(MediaStore.MediaColumns.IS_PENDING, 1)
            }
        val uri =
            withContext(Dispatchers.IO) { resolver.insert(LocalIds.collection(volume, type), values) }
                ?: throw IOException("MediaStore refused the new item")
        try {
            val out = withContext(Dispatchers.IO) { resolver.openOutputStream(uri, "w") } ?: throw IOException("cannot write $uri")
            out.use { downloader.download(assetId, it) }
            withContext(Dispatchers.IO) {
                resolver.update(uri, ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) }, null, null)
            }
        } catch (e: Throwable) {
            withContext(Dispatchers.IO + kotlinx.coroutines.NonCancellable) { runCatching { resolver.delete(uri, null, null) } }
            throw e
        }
        return LocalIds.of(volume, type, ContentUris.parseId(uri))
    }

    companion object {
        const val RELATIVE_PATH = "DCIM/PicTunnel/"
    }
}
