package io.github.prithvirajg.pictunnel.engine.bridge

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Bundle
import android.os.Looper
import androidx.activity.ComponentActivity
import androidx.activity.result.contract.ActivityResultContracts.RequestMultiplePermissions
import io.github.prithvirajg.pictunnel.engine.platform.PermissionDialog
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.async
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.android.controller.ActivityController

/** Registers [PermissionDialog] in onCreate, as MainActivity does. */
class PermissionHostActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        PermissionDialog.register(this)
    }
}

/** "Allow full access": the permission dialog registered at activity creation answers the waiting request. */
@OptIn(ExperimentalCoroutinesApi::class)
@RunWith(RobolectricTestRunner::class)
class PermissionDialogTest {
    private val perms = listOf(Manifest.permission.READ_MEDIA_IMAGES, Manifest.permission.READ_MEDIA_VIDEO)

    private fun request(): Deferred<Map<String, Boolean>?> =
        CoroutineScope(Dispatchers.Main).async { PermissionDialog.request(perms) }.also { idle() }

    private fun idle() = shadowOf(Looper.getMainLooper()).idle()

    private fun answer(
        c: ActivityController<PermissionHostActivity>,
        granted: IntArray,
    ) {
        val req = shadowOf(c.get()).lastRequestedPermission
        assertEquals("the permission dialog was shown", perms, req.requestedPermissions.toList())
        val data =
            Intent(RequestMultiplePermissions.ACTION_REQUEST_PERMISSIONS)
                .putExtra(RequestMultiplePermissions.EXTRA_PERMISSIONS, perms.toTypedArray())
                .putExtra(RequestMultiplePermissions.EXTRA_PERMISSION_GRANT_RESULTS, granted)
        c.get().activityResultRegistry.dispatchResult(req.requestCode, Activity.RESULT_OK, data)
        idle()
    }

    @Test fun theUsersAnswerReachesTheRequest() {
        val c = Robolectric.buildActivity(PermissionHostActivity::class.java).setup()
        assertTrue(PermissionDialog.attached)
        val pending = request()
        assertFalse("waiting for the user", pending.isCompleted)
        answer(c, intArrayOf(PackageManager.PERMISSION_GRANTED, PackageManager.PERMISSION_DENIED))
        assertEquals(mapOf(perms[0] to true, perms[1] to false), pending.getCompleted())
        c.pause().stop().destroy()
    }

    @Test fun finishingTheActivityAnswersNothingInsteadOfHanging() {
        val c = Robolectric.buildActivity(PermissionHostActivity::class.java).setup()
        val pending = request()
        c.get().finish()
        c.pause().stop().destroy()
        idle()
        assertEquals(emptyMap<String, Boolean>(), pending.getCompleted())
        assertFalse(PermissionDialog.attached)
        assertNull("no activity, no dialog", request().getCompleted())
    }
}
