package io.github.prithvirajg.pictunnel.engine.platform

import android.content.ContentProvider
import android.content.ContentUris
import android.content.ContentValues
import android.content.pm.ProviderInfo
import android.database.Cursor
import android.database.sqlite.SQLiteDatabase
import android.net.Uri
import android.os.ParcelFileDescriptor
import androidx.test.core.app.ApplicationProvider
import org.robolectric.Robolectric
import java.io.File

/**
 * A MediaStore stand-in registered under the `media` authority: rows live in an
 * in-memory SQLite table (so the scanner's real selections run unchanged) and
 * bytes in files. Every insert or update bumps a database-wide generation, as
 * MediaProvider does. [granted], when set, emulates partial media access: only
 * those ids (plus rows this app owns) are visible.
 */
class FakeMediaProvider : ContentProvider() {
    private lateinit var db: SQLiteDatabase
    private lateinit var dir: File

    var generation = 0L
        private set

    @Volatile var granted: Set<Long>? = null

    /** API 29 emulation: deletes throw RecoverableSecurityException until [consented]. */
    @Volatile var requireConsent = false

    @Volatile var consented = false

    override fun onCreate(): Boolean {
        db = SQLiteDatabase.create(null)
        db.execSQL(
            """
            CREATE TABLE media(
              _id INTEGER PRIMARY KEY AUTOINCREMENT,
              volume TEXT NOT NULL, media_type TEXT NOT NULL,
              _display_name TEXT, mime_type TEXT, _size INTEGER,
              date_modified INTEGER, datetaken INTEGER, date_added INTEGER,
              width INTEGER, height INTEGER, duration INTEGER,
              bucket_id INTEGER, relative_path TEXT,
              is_pending INTEGER NOT NULL DEFAULT 0,
              generation_modified INTEGER NOT NULL DEFAULT 0,
              owned INTEGER NOT NULL DEFAULT 0)
            """,
        )
        dir = File(ApplicationProvider.getApplicationContext<android.content.Context>().cacheDir, "fake-media").apply {
            deleteRecursively()
            mkdirs()
        }
        return true
    }

    private data class Target(
        val volume: String,
        val type: String,
        val id: Long?,
    )

    private fun target(uri: Uri): Target {
        // content://media/<volume>/<images|video>/media[/<id>]
        val seg = uri.pathSegments
        require(seg.size >= 3 && seg[2] == "media") { "unsupported uri $uri" }
        val type =
            when (seg[1]) {
                "images" -> "image"
                "video" -> "video"
                else -> error("unsupported collection $uri")
            }
        return Target(seg[0], type, seg.getOrNull(3)?.toLong())
    }

    private fun where(
        t: Target,
        selection: String?,
        includePending: Boolean = false,
    ): Pair<String, Array<String>> {
        val parts = mutableListOf("volume = ?", "media_type = ?")
        val args = mutableListOf(t.volume, t.type)
        if (t.id != null) {
            parts += "_id = ?"
            args += t.id.toString()
        }
        if (!includePending) parts += "(is_pending = 0 OR owned = 1)"
        granted?.let { g -> parts += "(owned = 1 OR _id IN (${g.joinToString(",").ifEmpty { "-1" }}))" }
        if (!selection.isNullOrBlank()) parts += "($selection)"
        return parts.joinToString(" AND ") to args.toTypedArray()
    }

    val queries = mutableListOf<String>()

    override fun query(
        uri: Uri,
        projection: Array<out String>?,
        selection: String?,
        selectionArgs: Array<out String>?,
        sortOrder: String?,
    ): Cursor {
        val t = target(uri)
        val (w, a) = where(t, selection)
        synchronized(queries) { queries += selection ?: "" }
        val cols = projection?.joinToString(",") ?: "*"
        return db.rawQuery("SELECT $cols FROM media WHERE $w" + (sortOrder?.let { " ORDER BY $it" } ?: ""), a + (selectionArgs ?: emptyArray()))
    }

    override fun getType(uri: Uri): String? = null

    override fun insert(
        uri: Uri,
        values: ContentValues?,
    ): Uri {
        val t = target(uri)
        val v = ContentValues(values ?: ContentValues())
        v.put("volume", t.volume)
        v.put("media_type", t.type)
        v.put("generation_modified", ++generation)
        v.put("owned", 1)
        val id = db.insertOrThrow("media", null, v)
        return ContentUris.withAppendedId(uri, id)
    }

    override fun delete(
        uri: Uri,
        selection: String?,
        selectionArgs: Array<out String>?,
    ): Int {
        val (w, a) = where(target(uri), selection, includePending = true)
        val ids = ids(w, a)
        if (requireConsent && !consented) {
            // API 29: deleting another app's media needs the user's consent first.
            val pi =
                android.app.PendingIntent.getActivity(
                    context!!,
                    0,
                    android.content.Intent("consent"),
                    android.app.PendingIntent.FLAG_IMMUTABLE,
                )
            val action =
                android.app.RemoteAction(
                    android.graphics.drawable.Icon
                        .createWithBitmap(android.graphics.Bitmap.createBitmap(1, 1, android.graphics.Bitmap.Config.ARGB_8888)),
                    "Allow",
                    "Allow",
                    pi,
                )
            throw android.app.RecoverableSecurityException(SecurityException("not owner"), "consent needed", action)
        }
        ids.forEach { file(it).delete() }
        return db.delete("media", w, a + (selectionArgs ?: emptyArray()))
    }

    override fun update(
        uri: Uri,
        values: ContentValues?,
        selection: String?,
        selectionArgs: Array<out String>?,
    ): Int {
        val (w, a) = where(target(uri), selection, includePending = true)
        val v = ContentValues(values ?: ContentValues())
        v.put("generation_modified", ++generation)
        return db.update("media", v, w, a + (selectionArgs ?: emptyArray()))
    }

    override fun openFile(
        uri: Uri,
        mode: String,
    ): ParcelFileDescriptor {
        val t = target(uri)
        val id = t.id ?: throw java.io.FileNotFoundException(uri.toString())
        val (w, a) = where(t, null, includePending = true)
        if (ids(w, a).isEmpty()) throw java.io.FileNotFoundException(uri.toString())
        val f = file(id)
        return if (mode.contains('w')) {
            ParcelFileDescriptor.open(
                f,
                ParcelFileDescriptor.MODE_WRITE_ONLY or ParcelFileDescriptor.MODE_CREATE or ParcelFileDescriptor.MODE_TRUNCATE,
            )
        } else {
            ParcelFileDescriptor.open(f, ParcelFileDescriptor.MODE_READ_ONLY)
        }
    }

    private fun ids(
        w: String,
        a: Array<String>,
    ): List<Long> =
        db.rawQuery("SELECT _id FROM media WHERE $w", a).use { c ->
            buildList { while (c.moveToNext()) add(c.getLong(0)) }
        }

    fun file(id: Long) = File(dir, "m$id")

    // ---- test helpers: media other apps (the camera) created ----------------

    /** Adds a camera photo or video; returns its MediaStore id. */
    fun add(
        volume: String = "external_primary",
        type: String = "image",
        bytes: ByteArray,
        name: String = "IMG.jpg",
        mime: String = if (type == "image") "image/jpeg" else "video/mp4",
        modifiedSec: Long = 1_700_000_000L,
        takenMs: Long? = 1_700_000_000_000L,
        width: Int? = 4000,
        height: Int? = 3000,
        durationMs: Long? = null,
        bucket: Long = 1,
    ): Long {
        val v =
            ContentValues().apply {
                put("volume", volume)
                put("media_type", type)
                put("_display_name", name)
                put("mime_type", mime)
                put("_size", bytes.size.toLong())
                put("date_modified", modifiedSec)
                put("datetaken", takenMs)
                put("date_added", modifiedSec)
                put("width", width)
                put("height", height)
                put("duration", durationMs)
                put("bucket_id", bucket)
                put("generation_modified", ++generation)
            }
        val id = db.insertOrThrow("media", null, v)
        file(id).writeBytes(bytes)
        return id
    }

    /** An in-place edit: new bytes, new modification time. */
    fun edit(
        id: Long,
        bytes: ByteArray,
        modifiedSec: Long,
    ) {
        file(id).writeBytes(bytes)
        db.execSQL(
            "UPDATE media SET _size = ?, date_modified = ?, generation_modified = ? WHERE _id = ?",
            arrayOf<Any>(bytes.size.toLong(), modifiedSec, ++generation, id),
        )
    }

    fun remove(id: Long) {
        file(id).delete()
        db.delete("media", "_id = ?", arrayOf(id.toString()))
    }

    fun exists(id: Long): Boolean = db.rawQuery("SELECT 1 FROM media WHERE _id = ?", arrayOf(id.toString())).use { it.moveToFirst() }

    fun row(id: Long): ContentValues? =
        db.rawQuery("SELECT * FROM media WHERE _id = ?", arrayOf(id.toString())).use { c ->
            if (!c.moveToFirst()) return null
            ContentValues().also { android.database.DatabaseUtils.cursorRowToContentValues(c, it) }
        }

    companion object {
        fun install(): FakeMediaProvider {
            val info = ProviderInfo().apply { authority = "media" }
            return Robolectric.buildContentProvider(FakeMediaProvider::class.java).create(info).get()
        }
    }
}

/** Volumes backed by the fake: versions are settable, the generation is the provider's. */
class FakeVolumes(
    private val provider: FakeMediaProvider,
) : MediaVolumes {
    val names = linkedSetOf("external_primary")
    val versions = HashMap<String, String>()

    override fun names(): Set<String> = names

    override fun version(volume: String): String = versions[volume] ?: "v1"

    override fun generation(volume: String): Long = provider.generation
}
