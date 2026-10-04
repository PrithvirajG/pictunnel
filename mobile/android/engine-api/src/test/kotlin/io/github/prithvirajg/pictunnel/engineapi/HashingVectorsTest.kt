package io.github.prithvirajg.pictunnel.engineapi

import java.io.File
import java.io.InputStream
import kotlin.test.Test
import kotlin.test.assertTrue
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long

class HashingVectorsTest {
    private val protocolDir = File(System.getProperty("pictunnel.protocolDir"))

    @Test
    fun allHashingVectorsMatch() {
        val files = File(protocolDir, "vectors/hashing").listFiles { f -> f.extension == "json" }.orEmpty().sortedBy { it.name }
        val failures = mutableListOf<String>()
        var count = 0
        for (file in files) {
            val cases = Json.parseToJsonElement(file.readText()).jsonObject.getValue("cases").jsonArray
            for (element in cases) {
                val case = element.jsonObject
                count++
                val name = case.getValue("name").jsonPrimitive.content
                val expected = case.getValue("expected_sha256").jsonPrimitive.content
                val actual = openInput(case.getValue("input").jsonObject).use { ContentHash.sha256Hex(it) }
                if (actual != expected) failures += "${file.name}/$name: expected $expected, got $actual"
            }
        }
        assertTrue(count >= 8, "expected at least 8 hashing cases in $protocolDir, found $count")
        assertTrue(failures.isEmpty(), failures.joinToString("\n"))
    }

    private fun openInput(input: JsonObject): InputStream = when {
        "file" in input -> File(protocolDir, input.getValue("file").jsonPrimitive.content).inputStream()
        "inline_utf8" in input -> input.getValue("inline_utf8").jsonPrimitive.content.toByteArray(Charsets.UTF_8).inputStream()
        "generate" in input -> input.getValue("generate").jsonObject.let { g ->
            CounterInputStream(g["seed"]?.jsonPrimitive?.int ?: 0, g.getValue("length").jsonPrimitive.long)
        }
        else -> error("unsupported hashing input: $input")
    }
}
