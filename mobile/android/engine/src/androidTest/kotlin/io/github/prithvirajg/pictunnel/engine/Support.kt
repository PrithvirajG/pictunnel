package io.github.prithvirajg.pictunnel.engine

import android.content.ContentUris
import android.content.ContentValues
import android.content.Context
import android.provider.MediaStore
import androidx.activity.ComponentActivity
import io.github.prithvirajg.pictunnel.engine.platform.LocalIds

/** An empty activity whose result registry launches the system dialogs. */
class HostActivity : ComponentActivity()

/** Inserts an image this app owns through MediaStore and returns its local id. */
fun insertImage(
    context: Context,
    name: String,
    bytes: ByteArray,
): String {
    val resolver = context.contentResolver
    val values =
        ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, name)
            put(MediaStore.MediaColumns.MIME_TYPE, "image/jpeg")
            put(MediaStore.MediaColumns.RELATIVE_PATH, "Pictures/PicTunnelTest/")
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }
    val uri = resolver.insert(MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY), values)!!
    resolver.openOutputStream(uri)!!.use { it.write(bytes) }
    resolver.update(uri, ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) }, null, null)
    return LocalIds.of(MediaStore.VOLUME_EXTERNAL_PRIMARY, LocalIds.IMAGE, ContentUris.parseId(uri))
}

/** Arbitrary bytes; MediaStore stores them without decoding. */
fun sampleBytes(seed: Int): ByteArray = ByteArray(2048) { ((it * 31) xor seed).toByte() }
