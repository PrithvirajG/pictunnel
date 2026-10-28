package io.github.prithvirajg.pictunnel.engine.core

import io.github.prithvirajg.pictunnel.engine.model.ItemKind
import io.github.prithvirajg.pictunnel.engine.model.PairRole

/**
 * Where the last scan of one media volume stopped (M§4.2): the MediaStore
 * generation, plus the volume version that forces a full rescan when it changes.
 */
data class ScanCursor(
    val volume: String,
    val generation: Long,
    val volumeVersion: String?,
)

/** One new or changed local media item, as the platform scanner sees it. */
data class ScannedItem(
    val localId: String,
    val size: Long,
    val modifiedAtMs: Long,
    val takenAtMs: Long,
    val mime: String,
    val kind: String = ItemKind.PHOTO,
    val filename: String,
    val pairRole: String = PairRole.PRIMARY,
    val pairLocalId: String? = null,
    val stackKey: String? = null,
    val width: Int? = null,
    val height: Int? = null,
    val durationMs: Long? = null,
)

/**
 * The result of one scan. [changed] holds new and changed items; [removed]
 * holds local ids deleted from the phone. With [fullRescan], [changed] is the
 * whole library and any indexed item missing from it is dropped from the index
 * too. Otherwise, a non-null [presentIds] is every id the scanner can still see
 * (incremental MediaStore scans cannot report deletions), and indexed items
 * missing from it are dropped. Deletions on the phone are never sent to the
 * server (R8). [cursors] replaces every stored cursor, one per media volume.
 */
data class ScanResult(
    val changed: List<ScannedItem>,
    val removed: List<String>,
    val cursors: List<ScanCursor>,
    val fullRescan: Boolean,
    val presentIds: Set<String>? = null,
)

/** How much of the media library the app may read (API 34+ partial access, M§4.6). */
enum class MediaAccess {
    /** Everything. */
    Full,

    /** Only items the user picked (`READ_MEDIA_VISUAL_USER_SELECTED`): only those are backed up. */
    Partial,

    /** Nothing: no media permission. */
    None,
}

/**
 * The platform scanner (MediaStore on Android). It applies the album
 * selection and the include-videos setting itself. [since] holds the stored
 * cursors (one per volume), empty for the first scan.
 */
interface Scanner {
    suspend fun scan(since: List<ScanCursor>): ScanResult

    /** The current media access; the bridge shows a banner when it is not [MediaAccess.Full]. */
    fun access(): MediaAccess = MediaAccess.Full
}
