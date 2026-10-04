package io.github.prithvirajg.pictunnel.engineapi

import java.io.InputStream

/** Byte i is (i + seed) mod 256 for i in [0, length). Mirrors the vector "counter" generator. */
class CounterInputStream(private val seed: Int, private val length: Long) : InputStream() {
    private var pos = 0L

    override fun read(): Int = if (pos >= length) -1 else ((pos++ + seed) % 256).toInt()

    override fun read(b: ByteArray, off: Int, len: Int): Int {
        if (pos >= length) return -1
        val n = minOf(len.toLong(), length - pos).toInt()
        for (i in 0 until n) b[off + i] = ((pos + i + seed) % 256).toByte()
        pos += n
        return n
    }
}
