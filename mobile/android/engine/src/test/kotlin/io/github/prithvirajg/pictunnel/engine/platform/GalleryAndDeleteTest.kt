package io.github.prithvirajg.pictunnel.engine.platform

import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.IntentSender
import androidx.test.core.app.ApplicationProvider
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import java.io.IOException

@RunWith(RobolectricTestRunner::class)
class GalleryAndDeleteTest {
    private lateinit var provider: FakeMediaProvider
    private val context: Context get() = ApplicationProvider.getApplicationContext()

    @Before fun setUp() {
        provider = FakeMediaProvider.install()
    }

    private fun sender(): IntentSender = PendingIntent.getActivity(context, 0, Intent("x"), PendingIntent.FLAG_IMMUTABLE).intentSender

    // ---- MediaStoreDeleter -----------------------------------------------------

    @Test fun deleteRequestConfirmsOnlyWhatTheUserDeleted() =
        runBlocking {
            val a = provider.add(bytes = ByteArray(1))
            val b = provider.add(bytes = ByteArray(2))
            val ids = listOf("external_primary:image:$a", "external_primary:image:$b")
            var requested: List<android.net.Uri> = emptyList()
            var shown = 0
            val deleter =
                MediaStoreDeleter(
                    context,
                    launcher = {
                        shown++
                        // The user taps Allow: the system deletes every requested item.
                        provider.remove(a)
                        provider.remove(b)
                        true
                    },
                    sdkInt = 34,
                    requestFactory = { uris ->
                        requested = uris
                        sender()
                    },
                )
            assertEquals(ids.toSet(), deleter.delete(ids))
            assertEquals(1, shown)
            assertEquals(ids.map { LocalIds.uri(it) }, requested)
        }

    @Test fun cancelledDialogConfirmsNothing() =
        runBlocking {
            val a = provider.add(bytes = ByteArray(1))
            val deleter = MediaStoreDeleter(context, launcher = { false }, sdkInt = 34, requestFactory = { sender() })
            assertEquals(emptySet<String>(), deleter.delete(listOf("external_primary:image:$a")))
            assertTrue(provider.exists(a))
        }

    @Test fun itemsAlreadyGoneAreNotReportedAsDeletedByTheUser() =
        runBlocking {
            val a = provider.add(bytes = ByteArray(1))
            val gone = provider.add(bytes = ByteArray(2))
            provider.remove(gone)
            var requested = 0
            val deleter =
                MediaStoreDeleter(context, launcher = {
                    provider.remove(a)
                    true
                }, sdkInt = 34, requestFactory = { uris ->
                    requested = uris.size
                    sender()
                })
            assertEquals(setOf("external_primary:image:$a"), deleter.delete(listOf("external_primary:image:$a", "external_primary:image:$gone")))
            assertEquals(1, requested)
        }

    @Test fun api29UsesRecoverableSecurityExceptionFlow() =
        runBlocking {
            val a = provider.add(bytes = ByteArray(1))
            provider.requireConsent = true
            var shown = 0
            val deleter =
                MediaStoreDeleter(context, launcher = {
                    shown++
                    provider.consented = true
                    true
                }, sdkInt = 29, requestFactory = { error("API 29 has no delete request") })
            assertEquals(setOf("external_primary:image:$a"), deleter.delete(listOf("external_primary:image:$a")))
            assertEquals(1, shown)
            assertFalse(provider.exists(a))
        }

    // ---- GalleryWriter ---------------------------------------------------------

    @Test fun saveToGalleryWritesAPendingRowThenPublishesIt() =
        runBlocking {
            val bytes = ByteArray(5000) { it.toByte() }
            var pendingWhileWriting: Any? = null
            val writer =
                GalleryWriter(context) { assetId, out ->
                    assertEquals("asset-9", assetId)
                    pendingWhileWriting = provider.row(1)?.getAsInteger("is_pending")
                    out.write(bytes)
                }
            val localId = writer.saveToGallery("asset-9", "beach.jpg", "image/jpeg")
            assertEquals("external_primary:image:1", localId)
            assertEquals(1, pendingWhileWriting)
            val row = provider.row(1)!!
            assertEquals(0, row.getAsInteger("is_pending"))
            assertEquals("beach.jpg", row.getAsString("_display_name"))
            assertEquals("image/jpeg", row.getAsString("mime_type"))
            assertEquals("DCIM/PicTunnel/", row.getAsString("relative_path"))
            assertArrayEquals(bytes, provider.file(1).readBytes())

            val video = GalleryWriter(context) { _, out -> out.write(1) }.saveToGallery("asset-2", "clip.mp4", "video/mp4")
            assertTrue(video.startsWith("external_primary:video:"))
        }

    @Test fun failedDownloadLeavesNoRowBehind() =
        runBlocking {
            val writer = GalleryWriter(context) { _, _ -> throw IOException("connection reset") }
            try {
                writer.saveToGallery("asset-1", "a.jpg", "image/jpeg")
                fail("expected the download failure")
            } catch (e: IOException) {
                assertEquals("connection reset", e.message)
            }
            assertFalse(provider.exists(1))
        }

    @Test(expected = IllegalArgumentException::class)
    fun nonMediaMimeIsRejected() {
        runBlocking { GalleryWriter(context) { _, _ -> }.saveToGallery("a", "doc.pdf", "application/pdf") }
    }
}
