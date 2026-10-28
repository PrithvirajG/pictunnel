package io.github.prithvirajg.pictunnel.engine.platform

import android.content.ContentResolver
import android.content.Context
import android.graphics.Bitmap
import android.provider.MediaStore
import android.util.Size
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.ByteArrayOutputStream

/** A MediaStore bucket (a folder such as Camera or Screenshots), for the album selection. */
data class Album(
    val id: String,
    val name: String,
    val count: Int,
)

/** Album listing and thumbnails for the app (M§3 `listAlbums`, `phoneThumbnail`). */
class MediaLibrary(
    private val resolver: ContentResolver,
    private val volumes: () -> Set<String>,
) {
    constructor(context: Context) : this(context.contentResolver, { MediaStore.getExternalVolumeNames(context) })

    /**
     * Every bucket holding photos or videos, across volumes, largest first. The
     * id is the `bucket_id` the scanner filters on.
     */
    suspend fun albums(): List<Album> =
        withContext(Dispatchers.IO) {
            val names = HashMap<String, String>()
            val counts = HashMap<String, Int>()
            for (volume in volumes()) {
                for (type in listOf(LocalIds.IMAGE, LocalIds.VIDEO)) {
                    val projection = arrayOf(MediaStore.MediaColumns.BUCKET_ID, MediaStore.MediaColumns.BUCKET_DISPLAY_NAME)
                    resolver
                        .query(LocalIds.collection(volume, type), projection, "${MediaStore.MediaColumns.IS_PENDING} = 0", null, null)
                        ?.use { c ->
                            val idCol = c.getColumnIndexOrThrow(MediaStore.MediaColumns.BUCKET_ID)
                            val nameCol = c.getColumnIndexOrThrow(MediaStore.MediaColumns.BUCKET_DISPLAY_NAME)
                            while (c.moveToNext()) {
                                if (c.isNull(idCol)) continue
                                val id = c.getLong(idCol).toString()
                                counts[id] = (counts[id] ?: 0) + 1
                                if (id !in names) names[id] = c.getString(nameCol) ?: ""
                            }
                        }
                }
            }
            counts
                .map { (id, n) -> Album(id, names[id]?.ifEmpty { null } ?: "Unnamed", n) }
                .sortedWith(compareByDescending<Album> { it.count }.thenBy { it.name })
        }

    /** A JPEG thumbnail about [sizePx] on its long side, from the system thumbnail cache. */
    suspend fun thumbnail(
        localId: String,
        sizePx: Int,
    ): ByteArray =
        withContext(Dispatchers.IO) {
            val px = sizePx.coerceIn(MIN_PX, MAX_PX)
            val bitmap = resolver.loadThumbnail(LocalIds.uri(localId), Size(px, px), null)
            try {
                ByteArrayOutputStream().use { out ->
                    bitmap.compress(Bitmap.CompressFormat.JPEG, JPEG_QUALITY, out)
                    out.toByteArray()
                }
            } finally {
                bitmap.recycle()
            }
        }

    private companion object {
        const val MIN_PX = 16
        const val MAX_PX = 1024
        const val JPEG_QUALITY = 85
    }
}
