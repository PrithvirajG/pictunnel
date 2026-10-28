package io.github.prithvirajg.pictunnel.engine.platform

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class NsdDiscoveryTest {
    @Test fun txtRecordMapsToServer() {
        val s =
            DiscoveredServer.from(
                "Home",
                "/192.168.1.20",
                8443,
                mapOf("sid" to "srv-1".toByteArray(), "v" to "1.2.0".toByteArray(), "api" to "1".toByteArray(), "fp16" to "ab12cd34ef56ab12".toByteArray()),
            )
        assertEquals(DiscoveredServer("Home", "192.168.1.20", 8443, "srv-1", "1.2.0", "1", "ab12cd34ef56ab12"), s)
        assertEquals("https://192.168.1.20:8443", s.url)
    }

    @Test fun missingKeysAndIpv6() {
        val s = DiscoveredServer.from("x", "fe80::1", 443, mapOf("sid" to null, "fp16" to ByteArray(0)))
        assertNull(s.serverId)
        assertNull(s.fp16)
        assertEquals("https://[fe80::1]:443", s.url)
    }
}
