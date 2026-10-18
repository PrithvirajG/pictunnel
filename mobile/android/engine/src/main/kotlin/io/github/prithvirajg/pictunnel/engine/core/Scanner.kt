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
 * too. Deletions on the phone are never sent to the server (R8).
 */
data class ScanResult(
    val changed: List<ScannedItem>,
    val removed: List<String>,
    val cursor: ScanCursor?,
    val fullRescan: Boolean,
)

/**
 * The platform scanner (MediaStore on Android, Task 9). It applies the album
 * selection and the include-videos setting itself. [since] is the last stored
 * cursor, or null for the first scan.
 */
interface Scanner {
    suspend fun scan(since: ScanCursor?): ScanResult
}
