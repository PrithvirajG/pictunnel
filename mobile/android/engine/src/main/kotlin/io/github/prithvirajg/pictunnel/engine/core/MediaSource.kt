package io.github.prithvirajg.pictunnel.engine.core

import io.github.prithvirajg.pictunnel.engine.net.UploadBody
import java.io.InputStream

/** The local file identity that keys the hash cache (R3) and guards free-up-space (P§7.8). */
data class Fingerprint(
    val modifiedAtMs: Long,
    val size: Long,
)

/** Reads local media bytes (ContentResolver on Android, Task 9). */
interface MediaSource {
    /** The exact original bytes (H1), streamed for hashing. */
    fun open(localId: String): InputStream

    /** The current fingerprint, or null when the item no longer exists on the phone. */
    fun fingerprint(localId: String): Fingerprint?

    /**
     * Upload bytes reopenable at any offset, for single-shot and chunked
     * uploads. Providers that cannot seek are copied to a cache file first (M§5).
     */
    fun openSeekable(localId: String): UploadBody
}
