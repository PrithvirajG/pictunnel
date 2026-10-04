package io.github.prithvirajg.pictunnel.engineapi

import java.io.InputStream
import java.security.MessageDigest

/** PicTunnel content identity: SHA-256 of the original bytes as lowercase hex. */
object ContentHash {
    private const val BUFFER_SIZE = 1 shl 20

    fun sha256Hex(input: InputStream): String {
        val digest = MessageDigest.getInstance("SHA-256")
        val buffer = ByteArray(BUFFER_SIZE)
        while (true) {
            val read = input.read(buffer)
            if (read < 0) break
            digest.update(buffer, 0, read)
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }
}
