package io.github.prithvirajg.pictunnel.engine.store

import androidx.room.testing.MigrationTestHelper
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/** v1 → v2 adds nullable width/height/durationMs and keeps every row (exported schemas are test assets). */
@RunWith(RobolectricTestRunner::class)
class MigrationTest {
    @get:Rule
    val helper = MigrationTestHelper(InstrumentationRegistry.getInstrumentation(), EngineDb::class.java)

    @Test
    fun v1ToV2KeepsRowsAndAddsNullableColumns() {
        helper.createDatabase(DB, 1).apply {
            execSQL(
                """
                INSERT INTO items (localId, sha256, size, modifiedAtMs, takenAtMs, mime, kind, pairRole, pairLocalId,
                    stackKey, state, attempts, nextAttemptAtMs, uploadId, uploadUrl, uploadOffset, assetId, lastError, filename)
                VALUES ('a', 'ff', 10, 1, 2, 'image/jpeg', 'photo', 'primary', NULL, NULL, 'BackedUp', 0, NULL, NULL, NULL,
                    NULL, 'asset-1', NULL, 'a.jpg')
                """.trimIndent(),
            )
            close()
        }
        val db = helper.runMigrationsAndValidate(DB, 2, true)
        db.query("SELECT localId, state, assetId, width, height, durationMs FROM items").use { c ->
            assertEquals(1, c.count)
            c.moveToFirst()
            assertEquals("a", c.getString(0))
            assertEquals("BackedUp", c.getString(1))
            assertEquals("asset-1", c.getString(2))
            assertEquals(true, c.isNull(3) && c.isNull(4) && c.isNull(5))
        }
        db.close()
    }

    private companion object {
        const val DB = "migration-test.db"
    }
}
