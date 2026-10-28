package io.github.prithvirajg.pictunnel.engine.platform

import android.app.Activity
import android.app.RecoverableSecurityException
import android.content.Context
import android.content.IntentSender
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import androidx.activity.result.ActivityResultRegistry
import androidx.activity.result.IntentSenderRequest
import androidx.activity.result.contract.ActivityResultContracts
import io.github.prithvirajg.pictunnel.engine.core.Deleter
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import java.util.UUID
import kotlin.coroutines.resume

/** Shows a system confirmation (an [IntentSender]) and returns true when the user accepted it. */
fun interface IntentSenderLauncher {
    suspend fun launch(sender: IntentSender): Boolean
}

/**
 * An [IntentSenderLauncher] on an activity's [ActivityResultRegistry]
 * (`StartIntentSenderForResult`). The bridge (Task 10) builds one from the
 * Flutter activity for each free-up request.
 */
class ActivityIntentSenderLauncher(
    private val registry: ActivityResultRegistry,
) : IntentSenderLauncher {
    override suspend fun launch(sender: IntentSender): Boolean =
        withContext(Dispatchers.Main) {
            suspendCancellableCoroutine { cont ->
                val key = "pictunnel.delete." + UUID.randomUUID()
                var launcher: androidx.activity.result.ActivityResultLauncher<IntentSenderRequest>? = null
                launcher =
                    registry.register(key, ActivityResultContracts.StartIntentSenderForResult()) { result ->
                        launcher?.unregister()
                        if (cont.isActive) cont.resume(result.resultCode == Activity.RESULT_OK)
                    }
                cont.invokeOnCancellation { launcher.unregister() }
                launcher.launch(IntentSenderRequest.Builder(sender).build())
            }
        }
}

/**
 * Deletes local originals through the OS confirmation dialog (M§4.5, P§7.8).
 * API 30+: one `MediaStore.createDeleteRequest` for every item. API 29: the
 * `RecoverableSecurityException` flow, one consent per item. The dialog is
 * always shown; what counts as confirmed is what is actually gone from
 * MediaStore afterwards, so a cancelled or partly applied request never marks
 * an item freed that still exists.
 */
class MediaStoreDeleter(
    context: Context,
    private val launcher: IntentSenderLauncher,
    private val sdkInt: Int = Build.VERSION.SDK_INT,
    private val requestFactory: (List<Uri>) -> IntentSender = { uris ->
        MediaStore.createDeleteRequest(context.contentResolver, uris).intentSender
    },
) : Deleter {
    private val resolver = context.contentResolver

    override suspend fun delete(localIds: List<String>): Set<String> {
        val existing = withContext(Dispatchers.IO) { localIds.filter { exists(it) } }
        if (existing.isEmpty()) return emptySet()
        if (sdkInt >= Build.VERSION_CODES.R) {
            // Only an accepted dialog confirms anything (M§4.5).
            if (!launcher.launch(requestFactory(existing.map { LocalIds.uri(it) }))) return emptySet()
        } else {
            for (id in existing) deleteWithConsent(LocalIds.uri(id))
        }
        return withContext(Dispatchers.IO) { existing.filterNot { exists(it) }.toSet() }
    }

    private suspend fun deleteWithConsent(uri: Uri) {
        try {
            withContext(Dispatchers.IO) { resolver.delete(uri, null, null) }
        } catch (e: RecoverableSecurityException) {
            if (launcher.launch(e.userAction.actionIntent.intentSender)) {
                withContext(Dispatchers.IO) { resolver.delete(uri, null, null) }
            }
        }
    }

    /** A failed query counts as "still there": an item is never reported freed on an unknown answer. */
    private fun exists(localId: String): Boolean =
        resolver.query(LocalIds.uri(localId), arrayOf(MediaStore.MediaColumns._ID), null, null, null)?.use { it.moveToFirst() } ?: true
}
