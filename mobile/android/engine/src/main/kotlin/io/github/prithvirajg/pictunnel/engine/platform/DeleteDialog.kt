package io.github.prithvirajg.pictunnel.engine.platform

import android.app.Activity
import android.content.IntentSender
import androidx.activity.ComponentActivity
import androidx.activity.result.ActivityResult
import androidx.activity.result.ActivityResultLauncher
import androidx.activity.result.IntentSenderRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

/**
 * The system delete dialog for free up space, surviving activity recreation.
 *
 * The activity calls [register] in `onCreate`, so its result launcher is
 * registered before STARTED with the same generated key every time: when the
 * activity is recreated (rotation, dark-mode switch) while the dialog is up,
 * the new activity's registration receives the result and completes the
 * request that is still waiting here. When the activity is finishing the
 * request resolves as declined, so free up space never hangs; any other
 * destruction is followed by a recreation that delivers the answer.
 *
 * Accepted trade-off: if the Flutter engine is cleaned up with the activity,
 * `EngineHost.close()` cancels the in-flight free-up call, so this request is
 * cancelled rather than answered (free up space still never hangs). Nothing
 * is lost: whatever the user did delete is gone from MediaStore, and the next
 * scan drops it from the index as it does any phone deletion.
 */
object DeleteDialog : IntentSenderLauncher {
    private val serial = Mutex()

    @Volatile private var launcher: ActivityResultLauncher<IntentSenderRequest>? = null

    @Volatile private var pending: CompletableDeferred<Boolean>? = null

    /** True while an activity that can show the dialog is registered. */
    val attached: Boolean get() = launcher != null

    /** Call from the activity's `onCreate` (before it is started). */
    fun register(activity: ComponentActivity) {
        val l = activity.registerForActivityResult(ActivityResultContracts.StartIntentSenderForResult(), ::onResult)
        launcher = l
        activity.lifecycle.addObserver(
            object : DefaultLifecycleObserver {
                override fun onDestroy(owner: LifecycleOwner) {
                    if (launcher === l) launcher = null
                    if (activity.isFinishing) resolve(false)
                }
            },
        )
    }

    /** Main thread. */
    internal fun onResult(result: ActivityResult) = resolve(result.resultCode == Activity.RESULT_OK)

    private fun resolve(accepted: Boolean) {
        pending?.complete(accepted)
        pending = null
    }

    /**
     * Shows [sender] and waits for the user's answer; one dialog at a time.
     * False when no activity is registered or it went away without answering.
     */
    override suspend fun launch(sender: IntentSender): Boolean =
        serial.withLock {
            val answer =
                withContext(Dispatchers.Main) {
                    val l = launcher ?: return@withContext null
                    CompletableDeferred<Boolean>().also {
                        pending = it
                        try {
                            l.launch(IntentSenderRequest.Builder(sender).build())
                        } catch (e: RuntimeException) {
                            pending = null
                            throw e
                        }
                    }
                } ?: return@withLock false
            try {
                answer.await()
            } finally {
                withContext(Dispatchers.Main + kotlinx.coroutines.NonCancellable) { if (pending === answer) pending = null }
            }
        }
}
