package io.github.prithvirajg.pictunnel.engine.platform

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.activity.ComponentActivity
import androidx.activity.result.ActivityResultLauncher
import androidx.activity.result.contract.ActivityResultContracts
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import io.github.prithvirajg.pictunnel.engine.core.MediaAccess
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.lang.ref.WeakReference

/** Shows the runtime permission dialog; null when no activity can show it. */
fun interface PermissionPrompt {
    suspend fun request(permissions: List<String>): Map<String, Boolean>?
}

/**
 * The runtime permission dialog for "Allow full access", registered like
 * [DeleteDialog]: the activity calls [register] in `onCreate`, so the result
 * launcher has the same key every time and an answer given while the activity
 * was recreated still reaches the waiting request. A finishing activity
 * resolves the request with no answers (nothing granted, settings not opened).
 */
object PermissionDialog : PermissionPrompt {
    private val serial = Mutex()

    @Volatile private var launcher: ActivityResultLauncher<Array<String>>? = null

    @Volatile private var activity: WeakReference<ComponentActivity>? = null

    @Volatile private var pending: CompletableDeferred<Map<String, Boolean>>? = null

    val attached: Boolean get() = launcher != null

    /** Call from the activity's `onCreate` (before it is started). */
    fun register(activity: ComponentActivity) {
        val l = activity.registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions(), ::onResult)
        launcher = l
        this.activity = WeakReference(activity)
        activity.lifecycle.addObserver(
            object : DefaultLifecycleObserver {
                override fun onDestroy(owner: LifecycleOwner) {
                    if (launcher === l) {
                        launcher = null
                        this@PermissionDialog.activity = null
                    }
                    if (activity.isFinishing) onResult(emptyMap())
                }
            },
        )
    }

    /** Main thread. */
    internal fun onResult(result: Map<String, Boolean>) {
        pending?.complete(result)
        pending = null
    }

    override suspend fun request(permissions: List<String>): Map<String, Boolean>? =
        serial.withLock {
            val answer =
                withContext(Dispatchers.Main) {
                    val l = launcher ?: return@withContext null
                    CompletableDeferred<Map<String, Boolean>>().also {
                        pending = it
                        try {
                            l.launch(permissions.toTypedArray())
                        } catch (e: RuntimeException) {
                            pending = null
                            throw e
                        }
                    }
                } ?: return@withLock null
            try {
                answer.await()
            } finally {
                withContext(Dispatchers.Main + NonCancellable) { if (pending === answer) pending = null }
            }
        }

    /**
     * After a denial: whether the system would still show the dialog for
     * [permission]. False means "don't ask again" (or no activity to ask).
     */
    fun canAskAgain(permission: String): Boolean = activity?.get()?.shouldShowRequestPermissionRationale(permission) ?: false

    /** The app's page in the system settings, where the user can grant access themselves. */
    fun openAppSettings(context: Context) {
        val from: Context = activity?.get() ?: context
        val intent =
            Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", context.packageName, null))
        if (from !is android.app.Activity) intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        from.startActivity(intent)
    }
}

/**
 * The "Allow full access" decision (M§4.2, partial media access):
 * - already full: nothing to ask;
 * - otherwise the read permissions (+ `ACCESS_MEDIA_LOCATION`) are requested;
 * - on API 34+ choosing "Select photos" is an answer: [MediaAccess.Partial];
 * - when the user can no longer be asked (denied with "don't ask again"),
 *   the app's settings page opens instead.
 * Returns the access afterwards, or null when no activity can show the dialog.
 */
class MediaAccessRequester(
    private val access: () -> MediaAccess,
    private val prompt: PermissionPrompt,
    private val canAskAgain: (String) -> Boolean,
    private val openSettings: () -> Unit,
    private val sdkInt: Int = Build.VERSION.SDK_INT,
) {
    suspend fun request(): MediaAccess? {
        val before = access()
        if (before == MediaAccess.Full) return before
        val answers = prompt.request(MediaPermissions.required(sdkInt)) ?: return null
        val after = access()
        if (after == MediaAccess.Full || answers.isEmpty()) return after
        if (sdkInt >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE && after == MediaAccess.Partial) return after
        val denied = fullReadPermissions().filter { answers[it] != true }
        if (denied.isNotEmpty() && denied.none(canAskAgain)) openSettings()
        return after
    }

    private fun fullReadPermissions(): List<String> =
        if (sdkInt >= Build.VERSION_CODES.TIRAMISU) {
            listOf(android.Manifest.permission.READ_MEDIA_IMAGES, android.Manifest.permission.READ_MEDIA_VIDEO)
        } else {
            listOf(android.Manifest.permission.READ_EXTERNAL_STORAGE)
        }
}
