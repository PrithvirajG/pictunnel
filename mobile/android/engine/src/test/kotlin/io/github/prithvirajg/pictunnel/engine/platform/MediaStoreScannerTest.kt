package io.github.prithvirajg.pictunnel.engine.platform

import android.content.ContentResolver
import androidx.test.core.app.ApplicationProvider
import io.github.prithvirajg.pictunnel.engine.core.EngineSettings
import io.github.prithvirajg.pictunnel.engine.core.MediaAccess
import io.github.prithvirajg.pictunnel.engine.core.ScanCursor
import io.github.prithvirajg.pictunnel.engine.core.ScanResult
import io.github.prithvirajg.pictunnel.engine.model.ItemKind
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

@RunWith(RobolectricTestRunner::class)
class MediaStoreScannerTest {
    private lateinit var provider: FakeMediaProvider
    private lateinit var volumes: FakeVolumes
    private val resolver: ContentResolver get() = ApplicationProvider.getApplicationContext<android.content.Context>().contentResolver
    private var settings = EngineSettings()
    private var access = MediaAccess.Full
    private var sdk = 34

    @Before fun setUp() {
        provider = FakeMediaProvider.install()
        volumes = FakeVolumes(provider)
    }

    private fun scanner() = MediaStoreScanner(resolver, { settings }, volumes, { access }, sdk)

    private fun scan(since: List<ScanCursor>): ScanResult = runBlocking { scanner().scan(since) }

    @Test fun firstScanFillsMetadataAndLocalIds() {
        val img = provider.add(bytes = ByteArray(10), name = "a.jpg", modifiedSec = 1_700_000_100, takenMs = 1_699_000_000_123)
        val vid =
            provider.add(type = "video", bytes = ByteArray(20), name = "b.mp4", width = 1920, height = 1080, durationMs = 4_500, takenMs = null)
        val r = scan(emptyList())
        assertTrue(r.fullRescan)
        assertEquals(2, r.changed.size)
        val a = r.changed.single { it.localId == "external_primary:image:$img" }
        assertEquals(10L, a.size)
        assertEquals(1_700_000_100_000L, a.modifiedAtMs)
        assertEquals(1_699_000_000_123L, a.takenAtMs)
        assertEquals("image/jpeg", a.mime)
        assertEquals(ItemKind.PHOTO, a.kind)
        assertEquals("a.jpg", a.filename)
        assertEquals(4000, a.width)
        assertEquals(3000, a.height)
        assertNull(a.durationMs)
        val b = r.changed.single { it.localId == "external_primary:video:$vid" }
        assertEquals(ItemKind.VIDEO, b.kind)
        assertEquals(1920, b.width)
        assertEquals(1080, b.height)
        assertEquals(4_500L, b.durationMs)
        // No date taken: falls back to date added.
        assertEquals(1_700_000_000_000L, b.takenAtMs)
        assertEquals(listOf(ScanCursor("external_primary", provider.generation, r.cursors.single().volumeVersion)), r.cursors)
    }

    @Test fun incrementalScanUsesGenerationAndReportsDeletes() {
        val a = provider.add(bytes = ByteArray(1))
        val b = provider.add(bytes = ByteArray(2))
        val first = scan(emptyList())
        provider.edit(a, ByteArray(5), 1_700_000_500)
        val c = provider.add(bytes = ByteArray(3))
        provider.remove(b)
        val r = scan(first.cursors)
        assertFalse(r.fullRescan)
        assertEquals(setOf("external_primary:image:$a", "external_primary:image:$c"), r.changed.map { it.localId }.toSet())
        assertEquals(5L, r.changed.single { it.localId.endsWith(":$a") }.size)
        // Deletions show up as ids missing from the present set.
        assertEquals(setOf("external_primary:image:$a", "external_primary:image:$c"), r.presentIds)
        assertTrue(provider.queries.any { it.contains("generation_modified > ?") })
    }

    @Test fun eachVolumeKeepsItsOwnCursor() {
        volumes.names += "1234-abcd"
        provider.add(bytes = ByteArray(1))
        val sd = provider.add(volume = "1234-abcd", bytes = ByteArray(2))
        val first = scan(emptyList())
        assertEquals(setOf("external_primary", "1234-abcd"), first.cursors.map { it.volume }.toSet())
        assertEquals(2, first.changed.size)
        assertTrue(first.changed.any { it.localId == "1234-abcd:image:$sd" })

        val sd2 = provider.add(volume = "1234-abcd", bytes = ByteArray(3))
        val r = scan(first.cursors)
        assertFalse(r.fullRescan)
        assertEquals(listOf("1234-abcd:image:$sd2"), r.changed.map { it.localId })
        assertEquals(3, r.presentIds!!.size)
    }

    @Test fun volumeChangesForceFullRescan() {
        provider.add(bytes = ByteArray(1))
        val first = scan(emptyList())
        // Same data, new volume version (MediaStore was rebuilt): generations are meaningless now.
        volumes.versions["external_primary"] = "v2"
        assertTrue(scan(first.cursors).fullRescan)
        // A volume appeared (SD card inserted).
        val second = scan(emptyList()).cursors
        volumes.names += "sd"
        assertTrue(scan(second).fullRescan)
    }

    @Test fun api29AlwaysScansInFull() {
        sdk = 29
        provider.add(bytes = ByteArray(1))
        val first = scan(emptyList())
        val r = scan(first.cursors)
        assertTrue(r.fullRescan)
        assertEquals(1, r.changed.size)
    }

    @Test fun albumSelectionAndVideosSettingFilterAndForceRescanOnChange() {
        val inAlbum = provider.add(bytes = ByteArray(1), bucket = 7)
        provider.add(bytes = ByteArray(2), bucket = 8)
        provider.add(type = "video", bytes = ByteArray(3), bucket = 7)
        settings = EngineSettings(includeVideos = false, allAlbums = false, albumIds = listOf("7"))
        val first = scan(emptyList())
        assertEquals(listOf("external_primary:image:$inAlbum"), first.changed.map { it.localId })

        settings = EngineSettings(includeVideos = true, allAlbums = true)
        val r = scan(first.cursors)
        assertTrue("a filter change rescans everything", r.fullRescan)
        assertEquals(3, r.changed.size)

        settings = EngineSettings(allAlbums = false, albumIds = emptyList())
        assertEquals(0, scan(r.cursors).changed.size)
    }

    @Test fun partialAccessScansGrantedItemsInFull() {
        val granted = provider.add(bytes = ByteArray(1))
        provider.add(bytes = ByteArray(2))
        provider.granted = setOf(granted)
        access = MediaAccess.Partial
        val first = scan(emptyList())
        assertEquals(listOf("external_primary:image:$granted"), first.changed.map { it.localId })
        // Newly granted items keep their old generation, so partial access never scans incrementally.
        val later = provider.add(bytes = ByteArray(3))
        provider.granted = setOf(granted, later)
        val r = scan(first.cursors)
        assertTrue(r.fullRescan)
        assertEquals(2, r.changed.size)
        assertEquals(MediaAccess.Partial, scanner().access())
    }

    @Test fun noAccessLeavesTheIndexAlone() {
        provider.add(bytes = ByteArray(1))
        val first = scan(emptyList())
        access = MediaAccess.None
        val r = scan(first.cursors)
        assertFalse(r.fullRescan)
        assertNull(r.presentIds)
        assertTrue(r.changed.isEmpty())
        assertEquals(first.cursors, r.cursors)
    }

    @Test fun pendingRowsAreIgnored() {
        provider.add(bytes = ByteArray(1))
        val pending = provider.add(bytes = ByteArray(2))
        provider.update(
            LocalIds.uri("external_primary:image:$pending"),
            android.content.ContentValues().apply { put("is_pending", 1) },
            null,
            null,
        )
        assertEquals(1, scan(emptyList()).changed.size)
    }
}
