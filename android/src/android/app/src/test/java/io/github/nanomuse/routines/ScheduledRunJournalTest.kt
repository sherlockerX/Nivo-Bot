package io.github.nanomuse.routines

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.time.LocalDate
import java.time.ZoneId

/** 日志和原子状态在普通JVM文件系统中验证，不接触真实home。 */
class ScheduledRunJournalTest {
    @get:Rule val temporary = TemporaryFolder()
    private fun run(id: String = "run") = JSONObject().put("run_id", id).put("started_at_ms", System.currentTimeMillis())
        .put("stdout_bytes", 719).put("stdout_sha256", "fixture").put("message_text_bytes", 719)

    @Test fun should_writeOneRecordAndReplaceValidState_when_finishingTwice() {
        val home = temporary.newFolder()
        val journal = ScheduledRunJournal(home)
        journal.write("task", run(), JSONObject().put("consecutive_failures", 1))
        journal.write("task", run(), JSONObject().put("consecutive_failures", 2))
        val result = journal.query("task")
        assertEquals(1, result.getJSONArray("runs").length())
        assertEquals(2, JSONObject(File(home, "state/scheduled/task.json").readText()).getInt("consecutive_failures"))
        assertFalse(File(home, "logs/scheduled/task").listFiles()!!.single().readText().contains("stdout\""))
    }

    @Test fun should_keepLogsButRemoveState_when_taskDeleted() {
        val home = temporary.newFolder()
        val journal = ScheduledRunJournal(home)
        journal.write("task", run(), JSONObject())
        journal.deleteState("task")
        assertFalse(File(home, "state/scheduled/task.json").exists())
        assertEquals("ok", journal.query("task").getString("status"))
        val empty = journal.query("missing")
        assertEquals("empty", empty.getString("status"))
        assertTrue(empty.has("queried"))
        assertFalse(empty.has("runs"))
    }

    @Test fun should_rotateOldDaysAndOversizedCurrentLog_when_writing() {
        val home = temporary.newFolder()
        val journal = ScheduledRunJournal(home)
        val dir = File(home, "logs/scheduled/task").also { it.mkdirs() }
        File(dir, "2000-01-01.jsonl").writeText("old\n")
        val today = LocalDate.now(ZoneId.of("Asia/Shanghai"))
        val large = File(dir, "$today.jsonl")
        large.bufferedWriter().use { writer -> repeat(7000) { writer.write("{\"fixture\":\"${"x".repeat(1000)}\"}\n") } }
        journal.write("task", run(), JSONObject())
        assertFalse(File(dir, "2000-01-01.jsonl").exists())
        assertTrue(dir.listFiles()!!.sumOf { it.length() } <= 5L * 1024 * 1024)
        assertTrue(large.readLines().last().contains("run_id"))
    }

    @Test fun should_rejectTraversalAndLeaveOldState_when_pathIsInvalid() {
        val journal = ScheduledRunJournal(temporary.newFolder())
        assertThrows(IllegalArgumentException::class.java) { journal.query("../outside") }
        assertThrows(IllegalArgumentException::class.java) { journal.write("a/b", run(), JSONObject()) }
    }
}
