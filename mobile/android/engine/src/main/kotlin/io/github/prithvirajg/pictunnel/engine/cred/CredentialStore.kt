package io.github.prithvirajg.pictunnel.engine.cred

/**
 * What pairing leaves on the device (M§4.4): the server identity, the endpoint
 * list in preference order (LAN first, then remote), the TLS pin (unpadded
 * base64url SHA-256 of the server SPKI, empty when none is needed), the current
 * refresh token and this device's id. The access token is never stored; it
 * lives in memory in [io.github.prithvirajg.pictunnel.engine.net.AuthManager].
 */
data class Credentials(
    val serverId: String,
    val endpoints: List<String>,
    val pinSpki: String,
    val refreshToken: String,
    val deviceId: String,
) {
    override fun toString(): String =
        "Credentials(serverId=$serverId, endpoints=$endpoints, pinSpki=$pinSpki, refreshToken=<redacted>, deviceId=$deviceId)"
}

/**
 * Durable, encrypted credential storage. The Keystore-backed implementation
 * arrives with the app wiring (Task 9). [save] must be durable when it returns:
 * the refresh token rotates on every refresh, and losing the new one forces a
 * re-pair once the server's 30 s grace window has passed.
 */
interface CredentialStore {
    fun load(): Credentials?

    fun save(c: Credentials)

    fun wipe()
}
