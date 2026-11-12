package io.github.nanomuse.todo

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

/** 容量等于边界时可用，超过一条或一个UTF-8字节时明确拒绝。 */
class TodoBackupLimitsTest {
    @Test fun should_acceptAllExactRowLimits_andRejectOneExtraInEachCollection() {
        val limits = mapOf("tasks" to 10_000, "links" to 50_000, "events" to 50_000, "operations" to 50_000)
        val json = JSONObject()
        limits.forEach { (name, count) -> json.put(name, JSONArray(List(count) { JSONObject.NULL })) }
        TodoBackupLimits.validateDocument(json)
        limits.forEach { (name, count) ->
            val rows = json.getJSONArray(name)
            rows.put(JSONObject.NULL)
            assertThrows(IllegalArgumentException::class.java) { TodoBackupLimits.validateDocument(json) }
            rows.remove(count)
        }
    }

    @Test fun should_countSupplementaryCharactersAsFourBytes_when_checkingTextBoundary() {
        val exact = "\uD83D\uDE00".repeat(2_000_000)
        assertEquals(8_000_000, exact.toByteArray(Charsets.UTF_8).size)
        TodoBackupLimits.validateText(exact)
        assertThrows(IllegalArgumentException::class.java) { TodoBackupLimits.validateText(exact + "a") }
    }
}
