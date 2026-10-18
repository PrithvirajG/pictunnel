package io.github.prithvirajg.pictunnel.engine.decide

import io.github.prithvirajg.pictunnel.engine.model.ItemKind
import io.github.prithvirajg.pictunnel.engine.model.ItemState
import io.github.prithvirajg.pictunnel.engine.model.MAX_ATTEMPTS
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import java.util.Random

/**
 * What the engine knew before the request that produced a [ServerOutcome]
 * (vector `given`). [itemState] is empty when the flow has no item (auth).
 * [item] carries flags such as `kind`, `attempts`, `has_upload_id` and
 * `fingerprint_changed`.
 */
data class Given(
    val flow: String,
    val itemState: String,
    val lastAction: String,
    val item: Map<String, Any?>,
)

/**
 * A server response, or a transport failure ([transport] is `timeout`, `reset`
 * or `offline`, and [status] is null). Header names compare case-insensitively.
 */
data class ServerOutcome(
    val status: Int?,
    val headers: Map<String, String>,
    val body: JsonElement?,
    val transport: String?,
) {
    fun header(name: String): String? = headers.entries.firstOrNull { it.key.equals(name, ignoreCase = true) }?.value
}

/**
 * The decision for one outcome. [nextState] is null only when the flow has no
 * item state to move (for example `retry_original_request` after a refresh).
 */
data class Decision(
    val nextState: ItemState?,
    val action: Action,
    val attemptsDelta: Int,
)

/** The P§10.5 action table. Constant names are the vector names upper-cased. */
enum class Action {
    MARK_BACKED_UP,
    QUEUE_UPLOAD,
    RESUME_UPLOAD,
    HEAD_THEN_RESUME,
    RESTART_UPLOAD,
    MARK_SKIPPED,
    REHASH_AND_REQUEUE,
    BACKOFF_RETRY,
    WAIT_RETRY_AFTER,
    WAIT_FOR_NETWORK,
    REFRESH_THEN_RETRY,
    RETRY_ORIGINAL_REQUEST,
    REQUIRE_REPAIR,
    PAUSE_ALL_UPLOADS,
    NOTIFY_QUOTA,
    PROMPT_UPDATE,
    MARK_NEEDS_ATTENTION,
    RUN_SNAPSHOT,
    RETRY_LATER,
    SKIP_THIS_RUN,
    UPLOAD_PRIMARY_FIRST,
    UPLOAD_LIVE_VIDEO,
    CHECK_THEN_RESOLVE,
    DELETE_LOCAL_ALLOWED,
    DELETE_LOCAL_DENIED,
    SHOW_ERROR,
    GO_TO_LOGIN,
}

/** Flows handled by the native engine. */
object Flow {
    const val BACKUP = "backup"
    const val AUTH = "auth"
    const val FREE_UP_SPACE = "free_up_space"
}

/** Values of `given.last_action` for the engine flows. */
object LastAction {
    const val CHECK = "check"
    const val CREATE_UPLOAD = "create_upload"
    const val APPEND_UPLOAD = "append_upload"
    const val HEAD_UPLOAD = "head_upload"
    const val REFRESH = "refresh"
    const val FREE_UP_SPACE_CHECK = "free_up_space_check"
}

/**
 * The pure decision function (M§2.1): `(given, serverOutcome) → decision`. No
 * I/O and no clock. Encodes the problem catalogue (P§8), R2, R4, R5, R7, R11
 * and the attempt-counting rules of P§10.5.
 */
object Decide {
    fun decide(
        g: Given,
        s: ServerOutcome,
    ): Decision =
        when (g.flow) {
            Flow.AUTH -> auth(g, s)
            Flow.FREE_UP_SPACE -> freeUpSpace(g, s)
            else -> escalate(g, backup(g, s))
        }

    // ---- backup -----------------------------------------------------------

    private fun backup(
        g: Given,
        s: ServerOutcome,
    ): Decision {
        val current = ItemState.parse(g.itemState)
        fun stay(
            action: Action,
            attempts: Int = 0,
        ) = Decision(current, action, attempts)

        val transport = s.transport
        if (transport != null) {
            // R5: no network is never an attempt; timeout and reset are.
            if (transport == TRANSPORT_OFFLINE) return stay(Action.WAIT_FOR_NETWORK)
            return when (g.lastAction) {
                // R2: the outcome is unknown. Ask HEAD for a known session, else check.
                LastAction.CREATE_UPLOAD, LastAction.APPEND_UPLOAD ->
                    if (hasUploadId(g)) {
                        Decision(ItemState.Uploading, Action.HEAD_THEN_RESUME, 1)
                    } else {
                        Decision(ItemState.Hashed, Action.CHECK_THEN_RESOLVE, 1)
                    }
                else -> stay(Action.BACKOFF_RETRY, 1)
            }
        }

        val status = s.status ?: return stay(Action.SKIP_THIS_RUN)
        if (status in 200..299) return backupSuccess(g, s, current)
        return problem(g, s, status, current)
    }

    private fun backupSuccess(
        g: Given,
        s: ServerOutcome,
        current: ItemState?,
    ): Decision {
        if (g.lastAction == LastAction.CHECK) {
            val result = firstResult(s.body) ?: return Decision(current, Action.SKIP_THIS_RUN, 0)
            return when (result.str("verdict")) {
                "exists" ->
                    when {
                        g.item["kind"] == ItemKind.LIVE_PHOTO && result.bool("has_live_video") == false ->
                            Decision(ItemState.Queued, Action.UPLOAD_LIVE_VIDEO, 0)
                        // R4: BackedUp only with a server asset id.
                        result.str("asset_id").isNullOrEmpty() -> Decision(current, Action.SKIP_THIS_RUN, 0)
                        else -> Decision(ItemState.BackedUp, Action.MARK_BACKED_UP, 0)
                    }
                "missing" -> Decision(ItemState.Queued, Action.QUEUE_UPLOAD, 0)
                "partial" -> Decision(ItemState.Uploading, Action.RESUME_UPLOAD, 0)
                "tombstoned" -> Decision(ItemState.Skipped, Action.MARK_SKIPPED, 0)
                else -> Decision(current, Action.SKIP_THIS_RUN, 0) // R7: unknown verdict
            }
        }
        // create (201), append (204) and HEAD (200): finalized once the server names the asset.
        if (!s.header(HEADER_ASSET_ID).isNullOrEmpty()) return Decision(ItemState.BackedUp, Action.MARK_BACKED_UP, 0)
        return Decision(ItemState.Uploading, Action.RESUME_UPLOAD, 0)
    }

    /** Maps a non-2xx response through the problem catalogue (P§8), then R7. */
    private fun problem(
        g: Given,
        s: ServerOutcome,
        status: Int,
        current: ItemState?,
    ): Decision {
        fun stay(
            action: Action,
            attempts: Int = 0,
        ) = Decision(current, action, attempts)
        val needsAttention = Decision(ItemState.NeedsAttention, Action.MARK_NEEDS_ATTENTION, 0)

        return when (problemCode(s.body) ?: headCode(g, status)) {
            "invalid_request", "forbidden", "file_too_large" -> needsAttention
            "unauthorized", "token_expired" -> stay(Action.REFRESH_THEN_RETRY)
            "refresh_token_reused" -> Decision(ItemState.Paused, Action.REQUIRE_REPAIR, 0)
            "not_found" ->
                if (isUploadAction(g.lastAction)) Decision(ItemState.Queued, Action.RESTART_UPLOAD, 0) else needsAttention
            "offset_mismatch" -> Decision(ItemState.Uploading, Action.HEAD_THEN_RESUME, 0)
            "length_mismatch", "checksum_mismatch" -> Decision(ItemState.Discovered, Action.REHASH_AND_REQUEUE, 1)
            "tombstoned" -> Decision(ItemState.Skipped, Action.MARK_SKIPPED, 0)
            "pair_primary_missing" -> Decision(ItemState.Queued, Action.UPLOAD_PRIMARY_FIRST, 0)
            "quota_exceeded" -> Decision(ItemState.Paused, Action.NOTIFY_QUOTA, 0)
            "insufficient_storage" -> Decision(ItemState.Paused, Action.PAUSE_ALL_UPLOADS, 0)
            "client_too_old" -> Decision(ItemState.Paused, Action.PROMPT_UPDATE, 0)
            "upload_locked", "internal" -> stay(Action.BACKOFF_RETRY, 1)
            "rate_limited" -> stay(Action.WAIT_RETRY_AFTER) // throttling is not an attempt
            "server_unavailable" -> serverUnavailable(s, current)
            else -> byStatus(s, status, current)
        }
    }

    /**
     * A HEAD response never carries a body, so its problem code is implied by
     * the status: `404` is the expired or unknown session of P§7.3 (restart
     * with POST).
     */
    private fun headCode(
        g: Given,
        status: Int,
    ): String? = if (g.lastAction == LastAction.HEAD_UPLOAD && status == 404) "not_found" else null

    /** R7: an unknown or missing problem code falls back to the HTTP status. */
    private fun byStatus(
        s: ServerOutcome,
        status: Int,
        current: ItemState?,
    ): Decision =
        when {
            status == 401 -> Decision(current, Action.REFRESH_THEN_RETRY, 0)
            status == 429 -> Decision(current, Action.WAIT_RETRY_AFTER, 0)
            status == 503 -> serverUnavailable(s, current)
            status in 400..499 -> Decision(ItemState.NeedsAttention, Action.MARK_NEEDS_ATTENTION, 0)
            status in 500..599 -> Decision(current, Action.BACKOFF_RETRY, 1)
            else -> Decision(current, Action.SKIP_THIS_RUN, 0)
        }

    /** 503 waits for `Retry-After` when present, else backs off; it counts as an attempt. */
    private fun serverUnavailable(
        s: ServerOutcome,
        current: ItemState?,
    ) = Decision(
        current,
        if (s.header(HEADER_RETRY_AFTER) != null) Action.WAIT_RETRY_AFTER else Action.BACKOFF_RETRY,
        1,
    )

    /** R5: the failure that would exceed [MAX_ATTEMPTS] stops retrying the item. */
    private fun escalate(
        g: Given,
        d: Decision,
    ): Decision {
        if (d.attemptsDelta <= 0) return d
        val attempts = (g.item["attempts"] as? Number)?.toInt() ?: 0
        return if (attempts + d.attemptsDelta >= MAX_ATTEMPTS) {
            Decision(ItemState.NeedsAttention, Action.MARK_NEEDS_ATTENTION, d.attemptsDelta)
        } else {
            d
        }
    }

    // ---- auth -------------------------------------------------------------

    /** Token refresh (P§6.2, R11). Auth failures are not item attempts. */
    private fun auth(
        g: Given,
        s: ServerOutcome,
    ): Decision {
        val current = ItemState.parse(g.itemState)
        val transport = s.transport
        if (transport != null) {
            // Network failure: keep the tokens and retry later (M§4.4).
            val action = if (transport == TRANSPORT_OFFLINE) Action.WAIT_FOR_NETWORK else Action.BACKOFF_RETRY
            return Decision(current, action, 0)
        }
        val status = s.status ?: return Decision(current, Action.SKIP_THIS_RUN, 0)
        return when {
            status in 200..299 -> Decision(current, Action.RETRY_ORIGINAL_REQUEST, 0)
            // Reused or revoked refresh credentials: wipe them and pair again.
            status == 401 || status == 403 -> Decision(ItemState.Paused, Action.REQUIRE_REPAIR, 0)
            problemCode(s.body) == "client_too_old" || status == 426 -> Decision(ItemState.Paused, Action.PROMPT_UPDATE, 0)
            status == 429 -> Decision(current, Action.WAIT_RETRY_AFTER, 0)
            status == 503 && s.header(HEADER_RETRY_AFTER) != null -> Decision(current, Action.WAIT_RETRY_AFTER, 0)
            status in 500..599 -> Decision(current, Action.BACKOFF_RETRY, 0)
            else -> Decision(current, Action.SHOW_ERROR, 0)
        }
    }

    // ---- free up space ----------------------------------------------------

    /**
     * P§7.8: deleting is allowed only if every result of the confirm_on_disk
     * check (both components of a Live Photo) is `exists`, `active`, `on_disk`
     * and the local fingerprint is unchanged. [ItemState.Freed] is applied only
     * after the user confirms the OS delete dialog (M§4.5). Any failure keeps
     * the local file; free-up is user-initiated, so nothing counts as an attempt.
     */
    private fun freeUpSpace(
        g: Given,
        s: ServerOutcome,
    ): Decision {
        val current = ItemState.parse(g.itemState)
        val denied = Decision(current, Action.DELETE_LOCAL_DENIED, 0)
        if (s.transport != null || s.status == null) return denied
        val status = s.status
        if (status == 401) return Decision(current, Action.REFRESH_THEN_RETRY, 0)
        if (status !in 200..299) return denied

        // The file changed since it was hashed: the server copy may differ, so re-hash.
        if (g.item["fingerprint_changed"] == true) return Decision(ItemState.Discovered, Action.DELETE_LOCAL_DENIED, 0)

        val results = results(s.body)
        if (results.isEmpty()) return denied
        for (r in results) {
            when (r.str("verdict")) {
                "exists" -> Unit
                "missing" -> return Decision(ItemState.Queued, Action.DELETE_LOCAL_DENIED, 0)
                "partial" -> return Decision(ItemState.Queued, Action.DELETE_LOCAL_DENIED, 0)
                "tombstoned" -> return Decision(ItemState.Skipped, Action.DELETE_LOCAL_DENIED, 0)
                else -> return denied
            }
        }
        val allSafe = results.all { it.str("asset_state") == "active" && it.bool("on_disk") == true }
        return if (allSafe) Decision(ItemState.Freed, Action.DELETE_LOCAL_ALLOWED, 0) else denied
    }

    // ---- helpers ----------------------------------------------------------

    private const val TRANSPORT_OFFLINE = "offline"
    private const val HEADER_ASSET_ID = "PicTunnel-Asset-Id"
    private const val HEADER_RETRY_AFTER = "Retry-After"

    private fun isUploadAction(a: String) =
        a == LastAction.CREATE_UPLOAD || a == LastAction.APPEND_UPLOAD || a == LastAction.HEAD_UPLOAD

    /** An append or HEAD always concerns a known session; a create only when the flag says so. */
    private fun hasUploadId(g: Given): Boolean =
        (g.item["has_upload_id"] as? Boolean) ?: (g.lastAction != LastAction.CREATE_UPLOAD)

    private fun results(body: JsonElement?): List<JsonObject> =
        ((body as? JsonObject)?.get("results") as? JsonArray)?.mapNotNull { it as? JsonObject } ?: emptyList()

    private fun firstResult(body: JsonElement?): JsonObject? = results(body).firstOrNull()

    private fun problemCode(body: JsonElement?): String? = (body as? JsonObject)?.str("code")

    private fun JsonObject.str(k: String): String? = (this[k] as? JsonPrimitive)?.takeIf { it.isString }?.content

    private fun JsonObject.bool(k: String): Boolean? = (this[k] as? JsonPrimitive)?.booleanOrNull
}

private const val BACKOFF_BASE_MS = 2_000L
private const val BACKOFF_CAP_MS = 900_000L

/**
 * R5 backoff with full jitter: a uniform delay in `[0, min(cap, base * 2^(attempt-1))]`
 * where [attempt] is the number of failures so far (1 for the first retry).
 */
fun backoffDelayMs(
    attempt: Int,
    random: Random,
): Long {
    val exp = (attempt - 1).coerceIn(0, 30)
    val ceiling = minOf(BACKOFF_CAP_MS, BACKOFF_BASE_MS shl exp)
    return (random.nextDouble() * (ceiling + 1)).toLong().coerceIn(0L, ceiling)
}
