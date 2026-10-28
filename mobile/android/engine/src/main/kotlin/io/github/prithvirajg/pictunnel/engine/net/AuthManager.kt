package io.github.prithvirajg.pictunnel.engine.net

import io.github.prithvirajg.pictunnel.engine.cred.CredentialStore
import io.github.prithvirajg.pictunnel.engine.decide.Action
import io.github.prithvirajg.pictunnel.engine.decide.Decide
import io.github.prithvirajg.pictunnel.engine.decide.Given
import io.github.prithvirajg.pictunnel.engine.decide.ServerOutcome
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.io.IOException

/** The result of a token refresh (P§6.2), already applied to the store. */
sealed interface RefreshOutcome {
    /** New (or grace-window identical) tokens are in place. */
    data class Refreshed(
        val accessToken: String,
    ) : RefreshOutcome {
        override fun toString(): String = "Refreshed(accessToken=<redacted>)"
    }

    /** Reused or revoked: credentials are wiped and the device must pair again. */
    data class NeedsRepair(
        val raw: ServerOutcome?,
    ) : RefreshOutcome

    /** `426 client_too_old` on refresh: prompt for an app update; tokens are kept. */
    data class ClientTooOld(
        val raw: ServerOutcome,
    ) : RefreshOutcome

    /**
     * Network or server trouble: tokens are kept; retry later. A 2xx whose
     * body did not parse keeps its status and headers but never its body,
     * which may hold tokens.
     */
    data class Transient(
        val raw: ServerOutcome?,
    ) : RefreshOutcome
}

/** [AuthManager.accessToken] could not produce a token. */
class AuthException(
    val outcome: RefreshOutcome,
) : IOException("no access token: $outcome")

/**
 * Access tokens for the engine (R11, M§4.4). The access token lives in memory
 * only; the rotating refresh token lives in [store], saved before the new
 * access token is handed out. Refreshes are single-flight: concurrent callers
 * that hit 401 with the same token share one refresh. Outcomes map through
 * decide()'s `auth` flow, so `refresh_token_reused` or a revoked device (any
 * 401/403) wipes the credentials and fires [onNeedsRepair], while network
 * failures keep everything for a later retry.
 *
 * [clock] is a monotonic millisecond clock (for example `elapsedRealtime`);
 * it only schedules a proactive refresh before the 15 min lifetime ends, so
 * correctness never depends on the device clock (R10). [endpoints] defaults to
 * the stored endpoint list; pass the [ServerClient]'s instance to share the
 * active endpoint. Every refresh carries `PicTunnel-Client: [clientHeader]`
 * whatever [client] is configured with.
 *
 * The refresh exchange, parse and save run non-cancellable (bounded by the
 * client's timeouts): once the server has rotated the token, cancelling the
 * caller must not lose the successor.
 */
class AuthManager(
    private val store: CredentialStore,
    client: OkHttpClient,
    private val clock: () -> Long,
    clientHeader: String,
    endpoints: Endpoints? = null,
) {
    private val client: OkHttpClient = client.newBuilder().addInterceptor(ClientHeaderInterceptor(clientHeader)).build()

    @Volatile var onNeedsRepair: () -> Unit = {}

    private val mutex = Mutex()

    @Volatile private var access: String? = null

    @Volatile private var accessValidUntil = 0L

    @Volatile private var endpoints: Endpoints? = endpoints

    /** Set by [close]: this session is over and never refreshes again. */
    @Volatile private var closed = false

    /** A valid access token, refreshing first when there is none or it is about to expire. */
    suspend fun accessToken(): String {
        val current = access
        if (current != null && clock() < accessValidUntil) return current
        return when (val r = refresh(stale = current)) {
            is RefreshOutcome.Refreshed -> r.accessToken
            else -> throw AuthException(r)
        }
    }

    /**
     * Call after a 401 (`unauthorized`/`token_expired`). Pass the token the
     * failed request used: if another caller already replaced it, no second
     * refresh happens. Without it the current token is assumed stale.
     */
    suspend fun onUnauthorized(staleToken: String? = null): RefreshOutcome = refresh(stale = staleToken ?: access)

    /** Forgets the in-memory access token (for example after re-pairing). */
    fun reset() {
        access = null
        accessValidUntil = 0
    }

    /**
     * Ends this session (unpair, or a new pairing about to store credentials):
     * waits for an in-flight refresh to finish, forgets the access token, runs
     * [block] (for example the credential wipe) under the refresh lock, and
     * refuses every later refresh.
     */
    suspend fun <T> close(block: suspend () -> T): T =
        mutex.withLock {
            closed = true
            access = null
            accessValidUntil = 0
            block()
        }

    /** Single flight: a caller whose token was already replaced gets the new one without a request. */
    private suspend fun refresh(stale: String?): RefreshOutcome =
        mutex.withLock {
            if (closed) return@withLock RefreshOutcome.NeedsRepair(NO_CREDENTIALS)
            val current = access
            if (current != null && current != stale && clock() < accessValidUntil) {
                return@withLock RefreshOutcome.Refreshed(current)
            }
            withContext(NonCancellable) { doRefresh() }
        }

    private suspend fun doRefresh(): RefreshOutcome {
        // Nothing stored: already wiped (or never paired); do not wipe or notify again.
        val creds = store.load() ?: return RefreshOutcome.NeedsRepair(NO_CREDENTIALS)
        val eps = endpoints ?: Endpoints(creds.endpoints).also { endpoints = it }
        val body = Problems.json.encodeToString(RefreshRequest.serializer(), RefreshRequest(creds.refreshToken))
        val out =
            try {
                Problems.outcome(
                    eps.execute(client, REFRESH_PATH) { url ->
                        Request.Builder().url(url).post(body.toRequestBody(JSON)).build()
                    },
                )
            } catch (e: IOException) {
                Problems.transport(e)
            }
        return when (Decide.decide(Given("auth", "", "refresh", emptyMap()), out).action) {
            Action.RETRY_ORIGINAL_REQUEST -> {
                val pair =
                    runCatching {
                        Problems.json.decodeFromJsonElement(TokenPair.serializer(), out.body ?: JsonObject(emptyMap()))
                    }.getOrNull() ?: return RefreshOutcome.Transient(out.copy(body = null))
                // Persist the rotated refresh token before anything uses the new access token,
                // unless the credentials were wiped or replaced while the refresh was in flight.
                if (!store.compareAndSave(creds.refreshToken, creds.copy(refreshToken = pair.refreshToken))) {
                    access = null
                    accessValidUntil = 0
                    return RefreshOutcome.NeedsRepair(NO_CREDENTIALS)
                }
                access = pair.accessToken
                accessValidUntil = clock() + ACCESS_REFRESH_AFTER_MS
                RefreshOutcome.Refreshed(pair.accessToken)
            }
            Action.REQUIRE_REPAIR -> repair(out)
            Action.PROMPT_UPDATE -> RefreshOutcome.ClientTooOld(out)
            else -> RefreshOutcome.Transient(out)
        }
    }

    private fun repair(raw: ServerOutcome): RefreshOutcome {
        access = null
        accessValidUntil = 0
        store.wipe()
        onNeedsRepair()
        return RefreshOutcome.NeedsRepair(raw)
    }

    @Serializable
    private data class RefreshRequest(
        @SerialName("refresh_token") val refreshToken: String,
    )

    @Serializable
    private data class TokenPair(
        @SerialName("access_token") val accessToken: String,
        @SerialName("refresh_token") val refreshToken: String,
    )

    companion object {
        const val REFRESH_PATH = "/api/v1/auth/refresh"

        /** Access tokens live 15 min (P§6.1); refresh a minute early. */
        const val ACCESS_REFRESH_AFTER_MS = 14 * 60 * 1000L

        private val JSON = "application/json".toMediaType()

        /**
         * There are no stored credentials: surfaced like a reused refresh token,
         * which decide() maps to require-repair.
         */
        internal val NO_CREDENTIALS =
            ServerOutcome(
                401,
                emptyMap(),
                JsonObject(
                    mapOf(
                        "code" to JsonPrimitive("refresh_token_reused"),
                        "detail" to JsonPrimitive("no stored credentials on this device"),
                    ),
                ),
                null,
            )
    }
}
