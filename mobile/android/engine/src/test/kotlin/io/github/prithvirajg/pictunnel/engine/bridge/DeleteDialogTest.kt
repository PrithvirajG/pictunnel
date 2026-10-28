package io.github.prithvirajg.pictunnel.engine.bridge

import android.app.Activity
import android.app.PendingIntent
import android.content.Intent
import android.content.IntentSender
import android.os.Bundle
import android.os.Looper
import androidx.activity.ComponentActivity
import androidx.test.core.app.ApplicationProvider
import io.github.prithvirajg.pictunnel.engine.platform.DeleteDialog
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.async
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.Shadows.shadowOf
import org.robolectric.android.controller.ActivityController
import org.robolectric.RobolectricTestRunner

/** Registers [DeleteDialog] in onCreate, as MainActivity does. */
class DialogHostActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        DeleteDialog.register(this)
    }
}

/** The free-up delete dialog (Task 9 carry): its answer reaches the engine even across activity recreation. */
@OptIn(ExperimentalCoroutinesApi::class)
@RunWith(RobolectricTestRunner::class)
class DeleteDialogTest {
    private val sender: IntentSender =
        PendingIntent
            .getActivity(ApplicationProvider.getApplicationContext(), 0, Intent("test.DELETE"), PendingIntent.FLAG_IMMUTABLE)
            .intentSender

    private fun launch(): Deferred<Boolean> =
        CoroutineScope(Dispatchers.Main).async { DeleteDialog.launch(sender) }.also { idle() }

    private fun idle() = shadowOf(Looper.getMainLooper()).idle()

    private fun answer(
        controller: ActivityController<DialogHostActivity>,
        requestCode: Int,
        resultCode: Int,
    ) {
        controller.get().activityResultRegistry.dispatchResult(requestCode, resultCode, null)
        idle()
    }

    private fun requestCode(controller: ActivityController<DialogHostActivity>): Int {
        val req = shadowOf(controller.get()).lastIntentSenderRequest
        assertEquals("the delete dialog was shown", sender, req.intentSender)
        return req.requestCode
    }

    @Test fun acceptedAndDeclinedAnswersReachTheEngine() {
        val c = Robolectric.buildActivity(DialogHostActivity::class.java).setup()
        assertTrue(DeleteDialog.attached)
        val yes = launch()
        answer(c, requestCode(c), Activity.RESULT_OK)
        assertTrue(yes.getCompleted())

        val no = launch()
        answer(c, requestCode(c), Activity.RESULT_CANCELED)
        assertFalse(no.getCompleted())
        c.pause().stop().destroy()
    }

    @Test fun answerSurvivesActivityRecreation() {
        val c = Robolectric.buildActivity(DialogHostActivity::class.java).setup()
        val pending = launch()
        val rc = requestCode(c)
        c.recreate()
        idle()
        assertFalse("still waiting for the user", pending.isCompleted)
        assertTrue(DeleteDialog.attached)
        answer(c, rc, Activity.RESULT_OK)
        assertTrue("the recreated activity delivered the answer", pending.getCompleted())
        c.pause().stop().destroy()
    }

    @Test fun finishingTheActivityDeclinesInsteadOfHanging() {
        val c = Robolectric.buildActivity(DialogHostActivity::class.java).setup()
        val pending = launch()
        c.get().finish()
        c.pause().stop().destroy()
        idle()
        assertFalse(pending.getCompleted())
        assertFalse(DeleteDialog.attached)
        assertFalse("no activity, no dialog", launch().getCompleted())
    }
}
