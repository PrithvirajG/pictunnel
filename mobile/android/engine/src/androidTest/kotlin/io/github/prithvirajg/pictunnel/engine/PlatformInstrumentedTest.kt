package io.github.prithvirajg.pictunnel.engine

import android.Manifest
import android.content.Context
import android.os.Build
import androidx.activity.result.ActivityResultRegistry
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.filters.SdkSuppress
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.rule.GrantPermissionRule
import androidx.test.uiautomator.By
import androidx.test.uiautomator.UiDevice
import androidx.test.uiautomator.Until
import io.github.prithvirajg.pictunnel.engine.core.EngineSettings
import io.github.prithvirajg.pictunnel.engine.cred.Credentials
import io.github.prithvirajg.pictunnel.engine.platform.ActivityIntentSenderLauncher
import io.github.prithvirajg.pictunnel.engine.platform.KeystoreCredentialStore
import io.github.prithvirajg.pictunnel.engine.platform.MediaStoreDeleter
import io.github.prithvirajg.pictunnel.engine.platform.MediaStoreScanner
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.util.regex.Pattern

/** Runs on an API 34 emulator in CI (Task 20); local builds only compile it. */
@RunWith(AndroidJUnit4::class)
class PlatformInstrumentedTest {
    private val context: Context get() = ApplicationProvider.getApplicationContext()

    @get:Rule
    val permissions: GrantPermissionRule =
        if (Build.VERSION.SDK_INT >= 33) {
            GrantPermissionRule.grant(Manifest.permission.READ_MEDIA_IMAGES, Manifest.permission.READ_MEDIA_VIDEO)
        } else {
            GrantPermissionRule.grant(Manifest.permission.READ_EXTERNAL_STORAGE)
        }

    @Test fun scanFindsInsertedImage() =
        runBlocking {
            val bytes = sampleBytes(1)
            val localId = insertImage(context, "pt-scan-${System.nanoTime()}.jpg", bytes)
            val scanner = MediaStoreScanner(context) { EngineSettings() }
            val first = scanner.scan(emptyList())
            val item = first.changed.single { it.localId == localId }
            assertEquals(bytes.size.toLong(), item.size)
            assertEquals("image/jpeg", item.mime)
            assertTrue(first.cursors.any { it.volume == "external_primary" })
            if (Build.VERSION.SDK_INT >= 30) {
                // Incremental: still present, not reported again.
                val second = scanner.scan(first.cursors)
                assertFalse(second.fullRescan)
                assertTrue(second.presentIds!!.contains(localId))
                assertTrue(second.changed.none { it.localId == localId })
            }
        }

    @Test fun keystoreRoundTrip() {
        val store = KeystoreCredentialStore.create(context)
        store.wipe()
        assertNull(store.load())
        val creds = Credentials("srv", listOf("https://192.168.1.2:8443"), "pin", "pt_rt_secret", "dev")
        store.save(creds)
        assertEquals(creds, KeystoreCredentialStore.create(context).load())
        val raw = File(context.noBackupFilesDir, KeystoreCredentialStore.FILE_NAME).readBytes()
        assertFalse(String(raw, Charsets.ISO_8859_1).contains("pt_rt_secret"))
        store.wipe()
        assertNull(store.load())
    }

    @SdkSuppress(minSdkVersion = 30)
    @Test fun deleteRequestShowsSystemDialog() {
        val localId = insertImage(context, "pt-delete-${System.nanoTime()}.jpg", sampleBytes(2))
        val device = UiDevice.getInstance(InstrumentationRegistry.getInstrumentation())
        ActivityScenario.launch(HostActivity::class.java).use { scenario ->
            var registry: ActivityResultRegistry? = null
            scenario.onActivity { registry = it.activityResultRegistry }
            val deleter = MediaStoreDeleter(context, ActivityIntentSenderLauncher(registry!!))
            runBlocking {
                val result = async(Dispatchers.Default) { deleter.delete(listOf(localId)) }
                val allow = device.wait(Until.findObject(By.text(Pattern.compile("(?i)allow|delete"))), 15_000)
                assertNotNull("the system delete dialog was not shown", allow)
                allow.click()
                assertEquals(setOf(localId), withTimeout(15_000) { result.await() })
            }
        }
    }
}
