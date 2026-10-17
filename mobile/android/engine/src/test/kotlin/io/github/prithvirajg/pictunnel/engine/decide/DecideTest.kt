package io.github.prithvirajg.pictunnel.engine.decide

import io.github.prithvirajg.pictunnel.engine.model.ItemState
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import java.util.Random

/** Rules from P§9/§10.5 that the shared vectors do not pin down on their own. */
class DecideTest {
    private fun uploading(attempts: Long) =
        Given("backup", "Uploading", "append_upload", mapOf("kind" to "photo", "has_upload_id" to true, "attempts" to attempts))

    @Test
    fun tenthRetryableFailureNeedsAttention() {
        val s = ServerOutcome(status = 500, headers = emptyMap(), body = null, transport = null)
        assertEquals(Decision(ItemState.Uploading, Action.BACKOFF_RETRY, 1), Decide.decide(uploading(8), s))
        assertEquals(Decision(ItemState.NeedsAttention, Action.MARK_NEEDS_ATTENTION, 1), Decide.decide(uploading(9), s))
    }

    @Test
    fun offlineNeverEscalates() {
        val s = ServerOutcome(status = null, headers = emptyMap(), body = null, transport = "offline")
        assertEquals(Decision(ItemState.Uploading, Action.WAIT_FOR_NETWORK, 0), Decide.decide(uploading(9), s))
    }

    @Test
    fun serverUnavailableWithoutRetryAfterBacksOff() {
        val s = ServerOutcome(status = 503, headers = emptyMap(), body = null, transport = null)
        assertEquals(Decision(ItemState.Uploading, Action.BACKOFF_RETRY, 1), Decide.decide(uploading(0), s))
    }

    @Test
    fun headersAreCaseInsensitive() {
        val g = Given("backup", "Uploading", "head_upload", mapOf("has_upload_id" to true))
        val s = ServerOutcome(200, mapOf("picTunnel-asset-id" to "x"), null, null)
        assertEquals(Decision(ItemState.BackedUp, Action.MARK_BACKED_UP, 0), Decide.decide(g, s))
    }

    @Test
    fun backoffIsFullJitterCappedAt15Minutes() {
        val r = Random(42)
        for (attempt in 1..20) {
            val ceiling = minOf(900_000L, 2_000L shl (attempt - 1).coerceAtMost(30))
            repeat(200) {
                val d = backoffDelayMs(attempt, r)
                assertTrue(d in 0..ceiling, "attempt $attempt gave $d > $ceiling")
            }
        }
        // The upper bound is reachable: a Random that always returns its maximum.
        val max =
            object : Random() {
                override fun nextDouble() = Math.nextDown(1.0)
            }
        assertEquals(2_000L, backoffDelayMs(1, max))
        assertEquals(4_000L, backoffDelayMs(2, max))
        assertEquals(900_000L, backoffDelayMs(50, max))
    }
}
