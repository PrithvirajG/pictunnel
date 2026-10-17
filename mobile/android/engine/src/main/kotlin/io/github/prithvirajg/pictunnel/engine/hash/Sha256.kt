package io.github.prithvirajg.pictunnel.engine.hash

import java.io.InputStream
import java.security.MessageDigest

/** Content identity (P§5, H1/H2): SHA-256 over the exact bytes, lowercase hex. */
object Sha256 {
    private const val BUFFER_BYTES = 1 shl 20 // 1 MiB

    /** Streams [input] through the digest without loading it into memory. Does not close [input]. */
    fun hex(input: InputStream): String {
        val md = MessageDigest.getInstance("SHA-256")
        val buf = ByteArray(BUFFER_BYTES)
        while (true) {
            val n = input.read(buf)
            if (n < 0) break
            md.update(buf, 0, n)
        }
        return md.digest().toHex()
    }

    fun hex(bytes: ByteArray): String = MessageDigest.getInstance("SHA-256").digest(bytes).toHex()

    private val HEX = "0123456789abcdef".toCharArray()

    private fun ByteArray.toHex(): String {
        val out = CharArray(size * 2)
        for (i in indices) {
            val v = this[i].toInt() and 0xFF
            out[i * 2] = HEX[v ushr 4]
            out[i * 2 + 1] = HEX[v and 0x0F]
        }
        return String(out)
    }
}
