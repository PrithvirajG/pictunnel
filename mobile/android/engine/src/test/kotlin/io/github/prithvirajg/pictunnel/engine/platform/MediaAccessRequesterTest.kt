package io.github.prithvirajg.pictunnel.engine.platform

import android.Manifest
import io.github.prithvirajg.pictunnel.engine.core.MediaAccess
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class MediaAccessRequesterTest {
    private class Harness(
        var access: MediaAccess,
        val sdk: Int,
        val answer: (List<String>) -> Map<String, Boolean>?,
        val askAgain: Boolean = true,
        /** The access the OS reports once the dialog was answered. */
        val afterAnswer: MediaAccess? = null,
    ) {
        val asked = ArrayList<List<String>>()
        var settingsOpened = 0

        fun requester() =
            MediaAccessRequester(
                access = { access },
                prompt = { perms ->
                    asked += perms
                    answer(perms).also { if (it != null && afterAnswer != null) access = afterAnswer }
                },
                canAskAgain = { askAgain },
                openSettings = { settingsOpened++ },
                sdkInt = sdk,
            )
    }

    @Test fun fullAccessAsksNothing() =
        runBlocking {
            val h = Harness(MediaAccess.Full, 34, { error("must not ask") })
            assertEquals(MediaAccess.Full, h.requester().request())
            assertTrue(h.asked.isEmpty())
        }

    @Test fun asksForReadAndLocationPermissionsAndReturnsTheGrant() =
        runBlocking {
            val h = Harness(MediaAccess.Partial, 34, { p -> p.associateWith { true } }, afterAnswer = MediaAccess.Full)
            assertEquals(MediaAccess.Full, h.requester().request())
            assertEquals(
                listOf(
                    Manifest.permission.READ_MEDIA_IMAGES, Manifest.permission.READ_MEDIA_VIDEO,
                    Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED, Manifest.permission.ACCESS_MEDIA_LOCATION,
                ),
                h.asked.single(),
            )
            assertEquals(0, h.settingsOpened)
        }

    @Test fun selectPhotosOnApi34IsPartialAndDoesNotOpenSettings() =
        runBlocking {
            val h =
                Harness(
                    MediaAccess.None, 34,
                    { mapOf(Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED to true, Manifest.permission.READ_MEDIA_IMAGES to false) },
                    askAgain = false, afterAnswer = MediaAccess.Partial,
                )
            assertEquals(MediaAccess.Partial, h.requester().request())
            assertEquals(0, h.settingsOpened)
        }

    @Test fun permanentlyDeniedOpensTheAppSettings() =
        runBlocking {
            val h = Harness(MediaAccess.None, 33, { p -> p.associateWith { false } }, askAgain = false)
            assertEquals(MediaAccess.None, h.requester().request())
            assertEquals(1, h.settingsOpened)
        }

    @Test fun aDenialThatCanBeAskedAgainDoesNotOpenSettings() =
        runBlocking {
            val h = Harness(MediaAccess.None, 33, { p -> p.associateWith { false } }, askAgain = true)
            assertEquals(MediaAccess.None, h.requester().request())
            assertEquals(0, h.settingsOpened)
        }

    @Test fun anInterruptedRequestOpensNothing() =
        runBlocking {
            val h = Harness(MediaAccess.None, 33, { emptyMap() }, askAgain = false)
            assertEquals(MediaAccess.None, h.requester().request())
            assertEquals(0, h.settingsOpened)
        }

    @Test fun noActivityIsNull() =
        runBlocking {
            val h = Harness(MediaAccess.None, 33, { null })
            assertNull(h.requester().request())
        }

    @Test fun beforeApi33TheStoragePermissionIsAsked() =
        runBlocking {
            val h = Harness(MediaAccess.None, 30, { p -> p.associateWith { true } }, afterAnswer = MediaAccess.Full)
            assertEquals(MediaAccess.Full, h.requester().request())
            assertEquals(listOf(Manifest.permission.READ_EXTERNAL_STORAGE, Manifest.permission.ACCESS_MEDIA_LOCATION), h.asked.single())
        }
}
