package io.github.prithvirajg.pictunnel.engine.platform

import android.content.Context
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
    private val requireOriginal: () -> Boolean = { LocationAccess.granted(context) },
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

    /**
     * One copy per item and fingerprint, named `<item>-<fingerprint>`. Only
     * stale copies of the same item (edited since) are removed, so concurrent
     * uploads never lose each other's copies; copies untouched for a week are
     * swept (the OS may also clear the cache directory).
     */
    private fun copyToCache(
        localId: String,
        uri: Uri,
    ): File {
        val dir = cacheDir.apply { mkdirs() }
        val item = hash(localId)
        val name = "$item-${hash(fingerprint(localId).toString())}"
        val target = File(dir, name)
        val weekAgo = System.currentTimeMillis() - STALE_COPY_MS
        dir.listFiles()?.forEach { f ->
            val staleVersion = f.name.startsWith("$item-") && f.name != name
            if (staleVersion || (f != target && f.lastModified() < weekAgo)) f.delete()
        }
        if (!target.exists()) {
            val tmp = File(dir, "$name.${Thread.currentThread().id}.tmp")
            (resolver.openInputStream(uri) ?: throw FileNotFoundException(localId)).use { inp ->
                tmp.outputStream().use { inp.copyTo(it) }
            }
            if (!tmp.renameTo(target) && !target.exists()) throw java.io.IOException("could not cache $localId")
            tmp.delete()
        }
        target.setLastModified(System.currentTimeMillis())
        return target
    }

    private fun hash(s: String): String =
        MessageDigest
            .getInstance("SHA-256")
            .digest(s.toByteArray())
            .take(12)
            .joinToString("") { "%02x".format(it) }

    private companion object {
        const val STALE_COPY_MS = 7L * 24 * 60 * 60 * 1000
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
