package io.github.prithvirajg.pictunnel.engineapi

import kotlin.test.Test
import kotlin.test.assertEquals

class ContentHashTest {
    @Test
    fun hashesKnownValues() {
        assertEquals("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", ContentHash.sha256Hex("abc".byteInputStream()))
        assertEquals("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", ContentHash.sha256Hex(ByteArray(0).inputStream()))
    }

    @Test
    fun counterStreamWrapsAt256() {
        val bytes = CounterInputStream(seed = 1, length = 258).readBytes()
        assertEquals(258, bytes.size)
        assertEquals(0, bytes[255].toInt() and 0xff)
        assertEquals(2, bytes[257].toInt() and 0xff)
    }
}
