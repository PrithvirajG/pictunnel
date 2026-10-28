package io.github.prithvirajg.pictunnel.engine.platform

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import androidx.room.withTransaction
import io.github.prithvirajg.pictunnel.engine.model.ItemState
import io.github.prithvirajg.pictunnel.engine.store.EngineDb
import io.github.prithvirajg.pictunnel.engine.store.SettingEntity

/** Whether MediaStore hands out unredacted originals (EXIF location kept, H1). */
object LocationAccess {
    fun granted(context: Context): Boolean =
        context.checkSelfPermission(Manifest.permission.ACCESS_MEDIA_LOCATION) == PackageManager.PERMISSION_GRANTED
}

/**
 * The bytes [ContentMediaSource] reads depend on `ACCESS_MEDIA_LOCATION`: with
 * it, the original; without it, a copy with the location redacted. When the
 * grant changes, every hash taken from the old bytes is wrong for the new
 * ones. [check] (run before each scan) then forgets the cached hashes of items
 * not yet backed up and sends them back to hashing, dropping any upload
 * session for the old bytes. Backed-up items keep their state: their asset is
 * on the server and free-up re-checks them against the server anyway.
 */
class OriginalBytesGuard(
    private val db: EngineDb,
    private val granted: () -> Boolean,
) {
    suspend fun check() {
        val now = granted().toString()
        val settings = db.settings()
        val before = settings.get(KEY)
        if (before == now) return
        db.withTransaction {
            if (before != null) {
                val sql = db.openHelper.writableDatabase
                val kept = KEPT.joinToString(",") { "'${it.name}'" }
                sql.execSQL("DELETE FROM hash_cache WHERE localId IN (SELECT localId FROM items WHERE state NOT IN ($kept))")
                sql.execSQL(
                    """
                    UPDATE items SET state = '${ItemState.Discovered.name}', sha256 = NULL, uploadId = NULL,
                        uploadUrl = NULL, uploadOffset = NULL, assetId = NULL, attempts = 0,
                        nextAttemptAtMs = NULL, lastError = NULL
                    WHERE state NOT IN ($kept)
                    """.trimIndent(),
                )
            }
            settings.put(SettingEntity(KEY, now))
        }
    }

    private companion object {
        const val KEY = "media_location_granted"
        val KEPT = listOf(ItemState.BackedUp, ItemState.Freed, ItemState.Skipped)
    }
}
