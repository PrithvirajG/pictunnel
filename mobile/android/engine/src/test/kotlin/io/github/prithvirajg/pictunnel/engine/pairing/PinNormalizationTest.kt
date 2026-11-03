package io.github.prithvirajg.pictunnel.engine.pairing

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Pins are normalized as the Dart and Swift sides do: trim, `+/` to `-_`, no `=`, 43 characters. */
class PinNormalizationTest {
    private val spki = "xKecCxNIWtM6GstVge3d62YGSu9rChlvCqOALKreFGc"

    @Test fun normalizeTrimsMapsAndStripsPadding() {
        assertEquals("ab-_cd", PairUri.normalizePin("  ab+/cd==\n"))
    }

    @Test fun exactPinMatches() {
        assertTrue(PairUri.acceptConnection(false, spki, spki))
    }

    @Test fun paddedAndWhitespacePinMatches() {
        assertTrue(PairUri.acceptConnection(false, spki, " $spki=\n"))
    }

    @Test fun standardBase64PinMatches() {
        val leaf = "a-b_" + spki.substring(4)
        val standard = "a+b/" + spki.substring(4) + "="
        assertTrue(PairUri.acceptConnection(false, leaf, standard))
    }

    @Test fun shortPinIsRejectedEvenAsAPrefix() {
        assertFalse(PairUri.acceptConnection(false, spki, spki.substring(0, 16)))
        assertFalse(PairUri.acceptConnection(false, spki.substring(0, 16), spki.substring(0, 16)))
        assertFalse(PairUri.acceptConnection(false, "", ""))
    }

    @Test fun differentPinIsRejected() {
        assertFalse(PairUri.acceptConnection(false, spki, "z0pEXVjYOhc0CN5i-OUFDhR6-JaPwKtubUrYBPzrVy4"))
    }

    @Test fun systemTrustedChainIsAccepted() {
        assertTrue(PairUri.acceptConnection(true, spki, ""))
    }
}
