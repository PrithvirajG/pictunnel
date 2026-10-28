package io.github.prithvirajg.pictunnel.engine.platform

import android.Manifest
import android.content.ContentResolver
import android.content.ContentUris
import android.content.Context
import android.content.pm.PackageManager
import android.database.Cursor
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import io.github.prithvirajg.pictunnel.engine.core.EngineSettings
import io.github.prithvirajg.pictunnel.engine.core.MediaAccess
import io.github.prithvirajg.pictunnel.engine.core.ScanCursor
import io.github.prithvirajg.pictunnel.engine.core.ScanResult
import io.github.prithvirajg.pictunnel.engine.core.ScannedItem
import io.github.prithvirajg.pictunnel.engine.core.Scanner
import io.github.prithvirajg.pictunnel.engine.model.ItemKind
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import java.security.MessageDigest

/**
 * Local ids of MediaStore items: `<volume>:<image|video>:<_id>`, for example
 * `external_primary:image:1234`. The id names the collection, so it maps back
 * to the content URI without a lookup.
 */
object LocalIds {
    const val IMAGE = "image"
    const val VIDEO = "video"

    fun of(
        volume: String,
        type: String,
        id: Long,
    ): String = "$volume:$type:$id"

    fun uri(localId: String): Uri {
        val parts = localId.split(':')
        require(parts.size == 3) { "not a MediaStore local id: $localId" }
        val id = parts[2].toLongOrNull() ?: throw IllegalArgumentException("not a MediaStore local id: $localId")
        return ContentUris.withAppendedId(collection(parts[0], parts[1]), id)
    }

    fun collection(
        volume: String,
        type: String,
    ): Uri =
        when (type) {
            IMAGE -> MediaStore.Images.Media.getContentUri(volume)
            VIDEO -> MediaStore.Video.Media.getContentUri(volume)
            else -> throw IllegalArgumentException("unknown media type $type")
        }
}

/** The MediaStore volume calls the scanner needs (static MediaStore methods; faked in tests). */
interface MediaVolumes {
    fun names(): Set<String>

    fun version(volume: String): String

    /** The volume's current generation, or null before API 30 (no generations). */
    fun generation(volume: String): Long?
}

class SystemMediaVolumes(
    private val context: Context,
) : MediaVolumes {
    override fun names(): Set<String> = MediaStore.getExternalVolumeNames(context)

    override fun version(volume: String): String = MediaStore.getVersion(context, volume)

    override fun generation(volume: String): Long? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) MediaStore.getGeneration(context, volume) else null
}

/** Media read access from the granted permissions (M§4.6). */
object MediaPermissions {
    /**
     * The runtime permissions to request on this API level. `ACCESS_MEDIA_LOCATION`
     * keeps EXIF location in the originals (H1); its grant changes the bytes, see [OriginalBytesGuard].
     */
    fun required(sdkInt: Int = Build.VERSION.SDK_INT): List<String> =
        readPermissions(sdkInt) + Manifest.permission.ACCESS_MEDIA_LOCATION

    private fun readPermissions(sdkInt: Int): List<String> =
        when {
            sdkInt >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE ->
                listOf(Manifest.permission.READ_MEDIA_IMAGES, Manifest.permission.READ_MEDIA_VIDEO, Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED)
            sdkInt >= Build.VERSION_CODES.TIRAMISU -> listOf(Manifest.permission.READ_MEDIA_IMAGES, Manifest.permission.READ_MEDIA_VIDEO)
            else -> listOf(Manifest.permission.READ_EXTERNAL_STORAGE)
        }

    fun access(
        context: Context,
        sdkInt: Int = Build.VERSION.SDK_INT,
    ): MediaAccess {
        fun has(p: String) = context.checkSelfPermission(p) == PackageManager.PERMISSION_GRANTED
        if (sdkInt < Build.VERSION_CODES.TIRAMISU) {
            return if (has(Manifest.permission.READ_EXTERNAL_STORAGE)) MediaAccess.Full else MediaAccess.None
        }
        val images = has(Manifest.permission.READ_MEDIA_IMAGES)
        val videos = has(Manifest.permission.READ_MEDIA_VIDEO)
        if (images && videos) return MediaAccess.Full
        val selected = sdkInt >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE && has(Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED)
        return if (images || videos || selected) MediaAccess.Partial else MediaAccess.None
    }
}

/**
 * Incremental MediaStore scanner (M§4.2): per volume, items whose
 * `generation_modified` is above the stored generation. A full rescan happens
 * on the first scan, when a volume's version changes, when a volume appears or
 * disappears, before API 30 (no generations), when the album/video scope
 * changed, and always under partial access (newly granted items keep their old
 * generation). Incremental scans also list every visible id so deletions on the
 * phone leave the index. Under partial access MediaStore itself returns only
 * the granted items, so only those are backed up.
 */
class MediaStoreScanner(
    private val resolver: ContentResolver,
    private val settings: suspend () -> EngineSettings,
    private val volumes: MediaVolumes,
    private val accessProvider: () -> MediaAccess,
    private val sdkInt: Int = Build.VERSION.SDK_INT,
    private val beforeScan: suspend () -> Unit = {},
) : Scanner {
    /**
     * The app's scanner. Before every scan it runs the [OriginalBytesGuard], so
     * a change of `ACCESS_MEDIA_LOCATION` re-hashes what is not yet backed up.
     */
    constructor(context: Context, db: io.github.prithvirajg.pictunnel.engine.store.EngineDb, settings: suspend () -> EngineSettings) : this(
        context.contentResolver,
        settings,
        SystemMediaVolumes(context),
        { MediaPermissions.access(context) },
        Build.VERSION.SDK_INT,
        OriginalBytesGuard(db) { LocationAccess.granted(context) }::check,
    )

    override fun access(): MediaAccess = accessProvider()

    override suspend fun scan(since: List<ScanCursor>): ScanResult =
        withContext(Dispatchers.IO) {
            beforeScan()
            val access = access()
            // Nothing is readable: keep the index as it is rather than dropping everything.
            if (access == MediaAccess.None) return@withContext ScanResult(emptyList(), emptyList(), since, fullRescan = false)

            val scope = Scope(settings())
            val prev = since.associateBy { it.volume }
            val names = volumes.names().sorted()
            // Generations are read before querying, so a change made during the scan is seen next time.
            val current = names.map { v -> ScanCursor(v, volumes.generation(v) ?: 0L, "${volumes.version(v)}#${scope.signature}") }
            val full =
                access == MediaAccess.Partial || sdkInt < Build.VERSION_CODES.R ||
                    prev.keys != names.toSet() ||
                    current.any { c -> prev[c.volume]?.volumeVersion != c.volumeVersion }

            val changed = ArrayList<ScannedItem>()
            val present = HashSet<String>()
            for (c in current) {
                for (type in scope.types) {
                    ensureActive()
                    query(c.volume, type, scope, if (full) null else prev.getValue(c.volume).generation, changed)
                    if (!full) ids(c.volume, type, scope, present)
                }
            }
            if (full) {
                ScanResult(changed, emptyList(), current, fullRescan = true)
            } else {
                ScanResult(changed, emptyList(), current, fullRescan = false, presentIds = present)
            }
        }

    /** The album selection and include-videos setting as a selection, plus a signature for the cursor. */
    private class Scope(
        s: EngineSettings,
    ) {
        val types: List<String> =
            when {
                !s.allAlbums && s.albumIds.isEmpty() -> emptyList()
                s.includeVideos -> listOf(LocalIds.IMAGE, LocalIds.VIDEO)
                else -> listOf(LocalIds.IMAGE)
            }
        val albums: List<String>? = if (s.allAlbums) null else s.albumIds.sorted()
        val signature: String =
            MessageDigest
                .getInstance("SHA-256")
                .digest("videos=${s.includeVideos};albums=${albums?.joinToString(",") ?: "*"}".toByteArray())
                .take(6)
                .joinToString("") { "%02x".format(it) }

        fun selection(afterGeneration: Long?): Pair<String, Array<String>> {
            val parts = mutableListOf("${MediaStore.MediaColumns.IS_PENDING} = 0")
            val args = mutableListOf<String>()
            if (afterGeneration != null) {
                parts += "$GENERATION_MODIFIED > ?"
                args += afterGeneration.toString()
            }
            if (albums != null) {
                parts += "${MediaStore.MediaColumns.BUCKET_ID} IN (${albums.joinToString(",") { "?" }})"
                args += albums
            }
            return parts.joinToString(" AND ") to args.toTypedArray()
        }
    }

    private fun query(
        volume: String,
        type: String,
        scope: Scope,
        afterGeneration: Long?,
        out: MutableList<ScannedItem>,
    ) {
        val (sel, args) = scope.selection(afterGeneration)
        val projection = if (type == LocalIds.VIDEO) PROJECTION + MediaStore.MediaColumns.DURATION else PROJECTION
        resolver.query(LocalIds.collection(volume, type), projection, sel, args, null).required(volume).use { c ->
            val id = c.getColumnIndexOrThrow(MediaStore.MediaColumns._ID)
            val name = c.getColumnIndexOrThrow(MediaStore.MediaColumns.DISPLAY_NAME)
            val mime = c.getColumnIndexOrThrow(MediaStore.MediaColumns.MIME_TYPE)
            val size = c.getColumnIndexOrThrow(MediaStore.MediaColumns.SIZE)
            val modified = c.getColumnIndexOrThrow(MediaStore.MediaColumns.DATE_MODIFIED)
            val taken = c.getColumnIndexOrThrow(MediaStore.MediaColumns.DATE_TAKEN)
            val added = c.getColumnIndexOrThrow(MediaStore.MediaColumns.DATE_ADDED)
            val width = c.getColumnIndexOrThrow(MediaStore.MediaColumns.WIDTH)
            val height = c.getColumnIndexOrThrow(MediaStore.MediaColumns.HEIGHT)
            val duration = c.getColumnIndex(MediaStore.MediaColumns.DURATION)
            while (c.moveToNext()) {
                val bytes = c.longOrNull(size) ?: continue
                if (bytes <= 0) continue
                val rowId = c.getLong(id)
                val modifiedMs = (c.longOrNull(modified) ?: 0L) * 1000
                out +=
                    ScannedItem(
                        localId = LocalIds.of(volume, type, rowId),
                        size = bytes,
                        modifiedAtMs = modifiedMs,
                        takenAtMs = c.longOrNull(taken)?.takeIf { it > 0 } ?: c.longOrNull(added)?.let { it * 1000 } ?: modifiedMs,
                        mime = c.getStringOrNull(mime) ?: if (type == LocalIds.VIDEO) "video/mp4" else "image/jpeg",
                        // Android motion photos are one file with an embedded video: a photo (H4).
                        kind = if (type == LocalIds.VIDEO) ItemKind.VIDEO else ItemKind.PHOTO,
                        filename = c.getStringOrNull(name) ?: "$type-$rowId",
                        width = c.intOrNull(width)?.takeIf { it > 0 },
                        height = c.intOrNull(height)?.takeIf { it > 0 },
                        durationMs = if (duration >= 0) c.longOrNull(duration)?.takeIf { it > 0 } else null,
                    )
            }
        }
    }

    private fun ids(
        volume: String,
        type: String,
        scope: Scope,
        out: MutableSet<String>,
    ) {
        val (sel, args) = scope.selection(null)
        resolver.query(LocalIds.collection(volume, type), arrayOf(MediaStore.MediaColumns._ID), sel, args, null).required(volume).use { c ->
            while (c.moveToNext()) out += LocalIds.of(volume, type, c.getLong(0))
        }
    }

    /** A null cursor would look like an empty library and drop the index: fail the scan instead. */
    private fun Cursor?.required(volume: String): Cursor = this ?: throw IllegalStateException("MediaStore query failed on $volume")

    private fun Cursor.longOrNull(i: Int): Long? = if (isNull(i)) null else getLong(i)

    private fun Cursor.intOrNull(i: Int): Int? = if (isNull(i)) null else getInt(i)

    private fun Cursor.getStringOrNull(i: Int): String? = if (isNull(i)) null else getString(i)

    private companion object {
        /** `MediaStore.MediaColumns.GENERATION_MODIFIED` (API 30). */
        const val GENERATION_MODIFIED = "generation_modified"

        val PROJECTION =
            arrayOf(
                MediaStore.MediaColumns._ID,
                MediaStore.MediaColumns.DISPLAY_NAME,
                MediaStore.MediaColumns.MIME_TYPE,
                MediaStore.MediaColumns.SIZE,
                MediaStore.MediaColumns.DATE_MODIFIED,
                MediaStore.MediaColumns.DATE_TAKEN,
                MediaStore.MediaColumns.DATE_ADDED,
                MediaStore.MediaColumns.WIDTH,
                MediaStore.MediaColumns.HEIGHT,
            )
    }
}
