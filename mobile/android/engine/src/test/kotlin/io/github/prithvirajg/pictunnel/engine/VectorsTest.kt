package io.github.prithvirajg.pictunnel.engine

import io.github.prithvirajg.pictunnel.engine.decide.Action
import io.github.prithvirajg.pictunnel.engine.decide.Decide
import io.github.prithvirajg.pictunnel.engine.decide.Decision
import io.github.prithvirajg.pictunnel.engine.decide.Given
import io.github.prithvirajg.pictunnel.engine.decide.ServerOutcome
import io.github.prithvirajg.pictunnel.engine.hash.Sha256
import io.github.prithvirajg.pictunnel.engine.model.ItemState
import io.github.prithvirajg.pictunnel.engine.pairing.PairUri
import io.github.prithvirajg.pictunnel.engine.pairing.PairUriResult
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.DynamicTest
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.TestFactory
import java.io.File
import java.io.InputStream

/**
 * Runs the shared protocol vectors (P§10): every client-decision case whose flow
 * belongs to the native engine (backup, auth, free_up_space), and every hashing
 * and pairing case. A failing vector is an engine bug; vectors are never edited.
 */
class VectorsTest {
    private val protocolDir =
        File(System.getProperty("pictunnel.protocolDir") ?: "../../../api/protocol")
    private val vectorsDir = File(protocolDir, "vectors")

    private fun cases(dir: String): List<Pair<String, JsonObject>> =
        File(vectorsDir, dir)
            .listFiles { f -> f.name.endsWith(".json") }!!
            .sortedBy { it.name }
            .flatMap { f ->
                Json.parseToJsonElement(f.readText()).jsonObject["cases"]!!.jsonArray
                    .map { "${f.nameWithoutExtension}/${it.jsonObject.str("name")}" to it.jsonObject }
            }

    // ---- client decisions -------------------------------------------------

    private fun clientDecisionCases(): List<Pair<String, JsonObject>> =
        cases("client-decisions").filter { (_, c) -> c.obj("given").str("flow") in ENGINE_FLOWS }

    @Test
    fun runsEveryEngineFlowCase() {
        val byFlow = cases("client-decisions").groupingBy { it.second.obj("given").str("flow") }.eachCount()
        println("client-decision cases by flow: $byFlow")
        assertEquals(ENGINE_FLOWS.sumOf { byFlow[it] ?: 0 }, clientDecisionCases().size)
        for (flow in ENGINE_FLOWS) assertTrue((byFlow[flow] ?: 0) > 0, "no vectors for flow $flow")
    }

    @TestFactory
    fun clientDecisions(): List<DynamicTest> =
        clientDecisionCases().map { (name, c) ->
            DynamicTest.dynamicTest(name) {
                val actual = Decide.decide(given(c.obj("given")), server(c.obj("server")))
                val exp = c.obj("expect")
                val expected =
                    Decision(
                        nextState = exp.strOrNull("next_state")?.let { ItemState.valueOf(it) },
                        action = Action.valueOf(exp.str("action").uppercase()),
                        attemptsDelta = exp["attempts_delta"]!!.jsonPrimitive.int,
                    )
                assertEquals(expected, actual, name)
            }
        }

    private fun given(g: JsonObject) =
        Given(
            flow = g.str("flow"),
            itemState = g.strOrNull("item_state") ?: "",
            lastAction = g.str("last_action"),
            item = (g["item"] as? JsonObject)?.mapValues { (_, v) -> scalar(v) } ?: emptyMap(),
        )

    private fun scalar(v: JsonElement): Any? {
        val p = v as? JsonPrimitive ?: return v
        return when {
            p.isString -> p.content
            p.booleanOrNull != null -> p.booleanOrNull
            p.longOrNull != null -> p.longOrNull
            else -> null
        }
    }

    private fun server(s: JsonObject): ServerOutcome {
        val status = s["status"]?.jsonPrimitive?.int
        val problem = s.strOrNull("problem")
        val body: JsonElement? =
            if (problem != null) {
                buildJsonObject {
                    put("type", "urn:pictunnel:problem:$problem")
                    put("title", problem)
                    put("status", status)
                    put("code", problem)
                }
            } else {
                s["json"]
            }
        return ServerOutcome(
            status = status,
            headers = (s["headers"] as? JsonObject)?.mapValues { it.value.jsonPrimitive.content } ?: emptyMap(),
            body = body,
            transport = s.strOrNull("transport"),
        )
    }

    // ---- hashing ----------------------------------------------------------

    @TestFactory
    fun hashing(): List<DynamicTest> =
        cases("hashing").map { (name, c) ->
            DynamicTest.dynamicTest(name) {
                val input = c.obj("input")
                val stream: InputStream =
                    when {
                        input["inline_utf8"] != null ->
                            input.str("inline_utf8").toByteArray(Charsets.UTF_8).inputStream()
                        input["file"] != null -> File(protocolDir, input.str("file")).inputStream()
                        else -> {
                            val gen = input.obj("generate")
                            assertEquals("counter", gen.str("pattern"))
                            val length = gen["length"]!!.jsonPrimitive.longOrNull!!
                            CounterInputStream(
                                seed = gen["seed"]?.jsonPrimitive?.int ?: 0,
                                start = gen["start"]?.jsonPrimitive?.longOrNull ?: 0L,
                                end = gen["end"]?.jsonPrimitive?.longOrNull ?: length,
                            )
                        }
                    }
                val actual = stream.use { Sha256.hex(it) }
                assertEquals(c.str("expected_sha256"), actual, name)
            }
        }

    @Test
    fun hashOfByteArrayMatchesFips() {
        assertEquals(
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
            Sha256.hex("abc".toByteArray()),
        )
    }

    /** P§10.1 counter pattern: byte i = (i + seed) mod 256, for i in [start, end). */
    private class CounterInputStream(
        private val seed: Int,
        start: Long,
        private val end: Long,
    ) : InputStream() {
        private var pos = start

        override fun read(): Int = if (pos >= end) -1 else ((pos++ + seed) and 0xFF).toInt()

        override fun read(
            b: ByteArray,
            off: Int,
            len: Int,
        ): Int {
            if (len == 0) return 0
            if (pos >= end) return -1
            val n = minOf(len.toLong(), end - pos).toInt()
            for (k in 0 until n) b[off + k] = ((pos + k + seed) and 0xFF).toByte()
            pos += n
            return n
        }
    }

    // ---- pairing ----------------------------------------------------------

    @TestFactory
    fun pairing(): List<DynamicTest> =
        cases("pairing").map { (name, c) ->
            DynamicTest.dynamicTest(name) {
                val exp = c.obj("expect")
                val result = PairUri.parse(c.str("uri"))
                when (exp.str("parse")) {
                    "error" -> assertEquals(PairUriResult.Error(exp.str("error")), result, name)
                    "ok" -> {
                        assertTrue(result is PairUriResult.Ok, "$name: expected ok, got $result")
                        val p = (result as PairUriResult.Ok).pair
                        exp.strOrNull("server_id")?.let { assertEquals(it, p.serverId) }
                        exp.strOrNull("code")?.let { assertEquals(it, p.code) }
                        exp.strOrNull("fingerprint")?.let { assertEquals(it, p.fingerprint) }
                        exp["endpoints"]?.let { e ->
                            assertEquals(e.jsonArray.map { it.jsonPrimitive.content }, p.endpoints)
                        }
                        val conn = c["connection"] as? JsonObject
                        if (conn != null) {
                            val accept =
                                PairUri.acceptConnection(
                                    systemTrusted = conn["system_trusted"]!!.jsonPrimitive.booleanOrNull!!,
                                    spkiSha256 = conn.str("spki_sha256"),
                                    pin = p.fingerprint,
                                )
                            assertEquals(exp["accept_connection"]!!.jsonPrimitive.booleanOrNull, accept, name)
                        }
                    }
                    else -> error("unknown parse expectation")
                }
            }
        }

    private companion object {
        val ENGINE_FLOWS = listOf("backup", "auth", "free_up_space")

        fun JsonObject.obj(k: String) = this[k]!!.jsonObject

        fun JsonObject.str(k: String) = this[k]!!.jsonPrimitive.content

        fun JsonObject.strOrNull(k: String) = (this[k] as? JsonPrimitive)?.content
    }
}
