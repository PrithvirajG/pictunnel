package io.github.prithvirajg.pictunnel.engine.pairing

import io.github.prithvirajg.pictunnel.engine.cred.CredentialStore
import io.github.prithvirajg.pictunnel.engine.cred.Credentials
import io.github.prithvirajg.pictunnel.engine.decide.ServerOutcome
import io.github.prithvirajg.pictunnel.engine.net.EngineHttp
import io.github.prithvirajg.pictunnel.engine.net.Endpoints
import io.github.prithvirajg.pictunnel.engine.net.PinningTrustManager
import io.github.prithvirajg.pictunnel.engine.net.Problems
import io.github.prithvirajg.pictunnel.engine.net.problem
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonObject
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.io.IOException
import javax.net.ssl.X509TrustManager

/** A successful pairing; credentials are already stored. */
data class PairResult(
    val serverId: String,
    val userName: String,
    val deviceId: String,
)

/**
 * Pairing failed. [code] is the server's problem code (`pairing_code_invalid`,
 * …), a transport kind (`tls` for a pin mismatch, `offline`, …), a P§10.3 URI
 * error, or `server_id_mismatch`.
 */
class PairException(
    val code: String,
    val raw: ServerOutcome? = null,
) : IOException("pairing failed: $code")

/**
 * Redeems a pairing code (P§6.3) over the QR URI's endpoints with the pinning
 * rule, then stores the server id, endpoints (in the URI's preference order),
 * pin, refresh token and device id. The access token from the redeem is not
 * kept: [io.github.prithvirajg.pictunnel.engine.net.AuthManager] refreshes on
 * first use.
 */
class Pairer(
    private val store: CredentialStore,
    private val clientHeader: String,
    private val appVersion: String,
    private val base: OkHttpClient = OkHttpClient(),
    private val systemTrust: X509TrustManager = PinningTrustManager.systemDefault(),
) {
    suspend fun pair(
        qrUri: String,
        deviceName: String,
    ): PairResult {
        val info =
            when (val p = PairUri.parse(qrUri)) {
                is PairUriResult.Ok -> p.pair
                is PairUriResult.Error -> throw PairException(p.code)
            }
        return redeem(info.serverId, info.endpoints, info.fingerprint, info.code, deviceName)
    }

    /**
     * Manual setup (P§6.3 step 5): redeems [code] at [serverUrl] pinning [pin],
     * the fingerprint the user confirmed after [TrustOnFirstUse]. The pin is
     * the server's identity here, so no server id is compared.
     */
    suspend fun pairManual(
        serverUrl: String,
        code: String,
        pin: String,
        deviceName: String,
    ): PairResult {
        if (pin.isEmpty()) throw PairException("missing_fingerprint")
        val origin = TrustOnFirstUse.origin(serverUrl)
        return redeem(null, listOf(origin), pin, code, deviceName)
    }

    private suspend fun redeem(
        expectedServerId: String?,
        endpoints: List<String>,
        fingerprint: String,
        code: String,
        deviceName: String,
    ): PairResult {
        val http = EngineHttp.newClient(fingerprint, clientHeader, base, systemTrust)
        val body =
            Problems.json.encodeToString(
                RedeemRequest.serializer(),
                RedeemRequest(code, RedeemDevice(deviceName, PLATFORM, appVersion)),
            )
        val raw =
            try {
                Problems.outcome(
                    Endpoints(endpoints).execute(http, REDEEM_PATH) { url ->
                        Request.Builder().url(url).post(body.toRequestBody(JSON)).build()
                    },
                )
            } catch (e: IOException) {
                Problems.transport(e)
            }
        if (raw.status != 201 && raw.status != 200) {
            throw PairException(raw.problem()?.code ?: raw.transport ?: "http_${raw.status}", raw)
        }
        val r =
            runCatching { Problems.json.decodeFromJsonElement(RedeemResponse.serializer(), raw.body ?: JsonObject(emptyMap())) }
                .getOrElse { throw PairException("bad_response", raw.copy(body = null)) }
        if (expectedServerId != null && r.serverId != expectedServerId) throw PairException("server_id_mismatch")
        store.save(Credentials(r.serverId, endpoints, fingerprint, r.tokens.refreshToken, r.device.id))
        return PairResult(r.serverId, r.user.username, r.device.id)
    }

    @Serializable
    private data class RedeemRequest(
        val code: String,
        val device: RedeemDevice,
    )

    @Serializable
    private data class RedeemDevice(
        @SerialName("device_name") val deviceName: String,
        val platform: String,
        @SerialName("app_version") val appVersion: String,
    )

    @Serializable
    private data class RedeemResponse(
        @SerialName("server_id") val serverId: String,
        val user: User,
        val device: Device,
        val tokens: Tokens,
    )

    @Serializable
    private data class User(
        val username: String,
    )

    @Serializable
    private data class Device(
        val id: String,
    )

    @Serializable
    private data class Tokens(
        @SerialName("refresh_token") val refreshToken: String,
    ) {
        override fun toString(): String = "Tokens(<redacted>)"
    }

    companion object {
        const val REDEEM_PATH = "/api/v1/pairing/redeem"
        const val PLATFORM = "android"
        private val JSON = "application/json".toMediaType()
    }
}
