package io.github.prithvirajg.pictunnel.engine

import android.content.Context
import android.media.MediaScannerConnection
import android.net.Uri
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.filters.SdkSuppress
import androidx.test.platform.app.InstrumentationRegistry
import io.github.prithvirajg.pictunnel.engine.core.EngineSettings
import io.github.prithvirajg.pictunnel.engine.core.MediaAccess
import io.github.prithvirajg.pictunnel.engine.platform.MediaPermissions
import io.github.prithvirajg.pictunnel.engine.platform.MediaStoreScanner
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Review Focus 4: with only READ_MEDIA_VISUAL_USER_SELECTED, only granted
 * items are backed up. Revoking a permission kills the process, so CI sets the
 * permission state before instrumenting (Task 20):
 *
 *     adb shell pm revoke io.github.prithvirajg.pictunnel.engine.test android.permission.READ_MEDIA_IMAGES
 *     adb shell pm revoke io.github.prithvirajg.pictunnel.engine.test android.permission.READ_MEDIA_VIDEO
 *     adb shell pm grant io.github.prithvirajg.pictunnel.engine.test android.permission.READ_MEDIA_VISUAL_USER_SELECTED
 *     adb shell am instrument -w -e class io.github.prithvirajg.pictunnel.engine.PartialAccessInstrumentedTest \
 *         io.github.prithvirajg.pictunnel.engine.test/androidx.test.runner.AndroidJUnitRunner
 *
 * Without that setup the test is skipped. Items this app inserted count as
 * granted; a screenshot written by the shell belongs to another owner and is not.
 */
@RunWith(AndroidJUnit4::class)
@SdkSuppress(minSdkVersion = 34)
class PartialAccessInstrumentedTest {
    private val context: Context get() = ApplicationProvider.getApplicationContext()

    @Test fun partialAccessBacksUpGrantedOnly() =
        runBlocking {
            assumeTrue("needs partial media access (see class doc)", MediaPermissions.access(context) == MediaAccess.Partial)

            val granted = insertImage(context, "pt-granted-${System.nanoTime()}.jpg", sampleBytes(3))
            val path = "/sdcard/Pictures/pt-shell-${System.nanoTime()}.png"
            InstrumentationRegistry.getInstrumentation().uiAutomation.executeShellCommand("screencap -p $path").close()
            val scanned = CompletableDeferred<Uri?>()
            MediaScannerConnection.scanFile(context, arrayOf(path), arrayOf("image/png")) { _, uri -> scanned.complete(uri) }
            val shellUri = withTimeout(20_000) { scanned.await() }
            assertNotNull("the shell's file was not indexed", shellUri)
            val shellId = "external_primary:image:" + shellUri!!.lastPathSegment

            val scanner = MediaStoreScanner(context) { EngineSettings() }
            assertEquals(MediaAccess.Partial, scanner.access())
            val r = scanner.scan(emptyList())
            assertTrue("partial access always scans in full", r.fullRescan)
            val ids = r.changed.map { it.localId }
            assertTrue(ids.contains(granted))
            assertFalse("an item the user did not select must not be backed up", ids.contains(shellId))
        }
}
