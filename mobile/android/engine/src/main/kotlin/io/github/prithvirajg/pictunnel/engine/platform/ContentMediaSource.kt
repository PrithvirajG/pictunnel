package io.github.prithvirajg.pictunnel.engine.platform

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.provider.MediaStore
import io.github.prithvirajg.pictunnel.engine.core.Fingerprint
import io.github.prithvirajg.pictunnel.engine.core.MediaSource
import io.github.prithvirajg.pictunnel.engine.net.UploadBody
import okio.Buffer
import okio.ForwardingSource
import okio.Source
import okio.source
import java.io.File
import java.io.FileNotFoundException
import java.io.InputStream
import java.security.MessageDigest

/**
 * Reads MediaStore items through the ContentResolver (M§5). With
 * `ACCESS_MEDIA_LOCATION` granted it asks for the original bytes
 * ([MediaStore.setRequireOriginal]) so EXIF location survives (H1); without it
 * MediaStore redacts the location, and the redacted bytes are what is hashed
 * and uploaded, consistently.
 */
class ContentMediaSource(
    private val context: Context,
    private val requireOriginal: () -> Boolean = {
        context.checkSelfPermission(Manifest.permission.ACCESS_MEDIA_LOCATION) == PackageManager.PERMISSION_GRANTED
    },
) : MediaSource {
    private val resolver = context.contentResolver
    private val cacheDir: File get() = File(context.cacheDir, "upload-copy")

    private fun readUri(localId: String): Uri {
        val uri = LocalIds.uri(localId)
        return if (requireOriginal()) MediaStore.setRequireOriginal(uri) else uri
    }

    override fun open(localId: String): InputStream =
        resolver.openInputStream(readUri(localId)) ?: throw FileNotFoundException(localId)

    override fun fingerprint(localId: String): Fingerprint? {
        val projection = arrayOf(MediaStore.MediaColumns.SIZE, MediaStore.MediaColumns.DATE_MODIFIED)
        resolver.query(LocalIds.uri(localId), projection, null, null, null)?.use { c ->
            if (!c.moveToFirst() || c.isNull(0)) return null
            return Fingerprint(modifiedAtMs = c.getLong(1) * 1000, size = c.getLong(0))
        }
        return null
    }

    /**
     * Seeks the provider's file descriptor when it is a regular file; a
     * provider that hands out a pipe is copied to a cache file once (M§5).
     */
    override fun openSeekable(localId: String): UploadBody {
        val uri = readUri(localId)
        val seekable =
            resolver.openFileDescriptor(uri, "r")?.use { it.statSize >= 0 }
                ?: throw FileNotFoundException(localId)
        if (!seekable) return UploadBody.of(copyToCache(localId, uri))
        return UploadBody { offset, length ->
            val pfd = resolver.openFileDescriptor(uri, "r") ?: throw FileNotFoundException(localId)
            val input = ParcelFileDescriptor.AutoCloseInputStream(pfd)
            try {
                require(offset >= 0 && length >= 0 && offset + length <= pfd.statSize) { "range out of bounds" }
                input.channel.position(offset)
                Limited(input.source(), length)
            } catch (e: Throwable) {
                input.close()
                throw e
            }
        }
    }

    private fun copyToCache(
        localId: String,
        uri: Uri,
    ): File {
        val dir = cacheDir.apply { mkdirs() }
        val name =
            MessageDigest
                .getInstance("SHA-256")
                // Keyed by the fingerprint too: an edited item never reuses a stale copy.
                .digest("$localId|${fingerprint(localId)}".toByteArray())
                .take(12)
                .joinToString("") { "%02x".format(it) }
        val target = File(dir, name)
        // Only the item being uploaded keeps a copy.
        dir.listFiles()?.filter { it.name != name }?.forEach { it.delete() }
        if (!target.exists()) {
            val tmp = File(dir, "$name.tmp")
            (resolver.openInputStream(uri) ?: throw FileNotFoundException(localId)).use { inp ->
                tmp.outputStream().use { inp.copyTo(it) }
            }
            if (!tmp.renameTo(target)) throw java.io.IOException("could not cache $localId")
        }
        return target
    }

    /** At most [limit] bytes of [delegate]. */
    private class Limited(
        delegate: Source,
        private var limit: Long,
    ) : ForwardingSource(delegate) {
        override fun read(
            sink: Buffer,
            byteCount: Long,
        ): Long {
            if (limit <= 0) return -1
            val n = super.read(sink, minOf(byteCount, limit))
            if (n > 0) limit -= n
            return n
        }
    }
}
