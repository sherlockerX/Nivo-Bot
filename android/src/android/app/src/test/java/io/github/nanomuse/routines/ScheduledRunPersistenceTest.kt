package io.github.nanomuse.routines

import android.content.Context
import android.content.SharedPreferences
import com.openminis.app.scheduled.*
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.mockito.Mockito.*
import java.io.File

/** 使用内存任务存储和临时home验证真实记录器的失败恢复。 */
class ScheduledRunPersistenceTest {
    @get:Rule val temporary = TemporaryFolder()

    private fun context(): Context {
        val context = mock(Context::class.java)
        val preferences = mock(SharedPreferences::class.java)
        val editor = mock(SharedPreferences.Editor::class.java)
        val values = mutableMapOf<String, Any?>()
        `when`(context.filesDir).thenReturn(temporary.newFolder())
        `when`(context.getSharedPreferences(anyString(), anyInt())).thenReturn(preferences)
        `when`(preferences.getString(anyString(), nullable(String::class.java))).thenAnswer {
            values[it.getArgument<String>(0)] as? String ?: it.getArgument<String?>(1)
        }
        `when`(preferences.getBoolean(anyString(), anyBoolean())).thenAnswer {
            values[it.getArgument<String>(0)] as? Boolean ?: it.getArgument<Boolean>(1)
        }
        `when`(preferences.edit()).thenReturn(editor)
        `when`(editor.putString(anyString(), nullable(String::class.java))).thenAnswer {
            values[it.getArgument(0)] = it.getArgument<String?>(1); editor
        }
        `when`(editor.putBoolean(anyString(), anyBoolean())).thenAnswer {
            values[it.getArgument(0)] = it.getArgument<Boolean>(1); editor
        }
        `when`(editor.commit()).thenReturn(true)
        return context
    }
    private fun task() = ScheduledTask(id = "task", label = "fixture", timeOfDayHour = 6, timeOfDayMinute = 0,
        repeatMode = ScheduledRepeatMode.DAILY, prompt = "fixture", origin = "user_cli")
    private fun run(id: String) = ScheduledRun(System.currentTimeMillis(), "fixture-session", "fixture", true,
        startedAtMs = System.currentTimeMillis() - 10, runId = id, outcome = "success", exitCode = 0)
    private fun details() = JSONObject().put("label", "fixture").put("stdout_bytes", 719)
        .put("message_text_bytes", 719).put("stdout_sha256", "fixture").put("error", JSONObject.NULL)

    @Test fun should_notFailBusinessOutcome_when_logPathIsUnavailable() {
        val context = context()
        val store = ScheduledTaskStore(context)
        store.upsert(task())
        val home = File(context.filesDir, "minis-global/home").also { it.mkdirs() }
        File(home, "logs").writeText("fixture path conflict")
        ScheduledRunRecorder.record(context, store, "task", run("first"), null, details())
        val result = store.get("task")!!
        assertEquals("success", result.runtime.lastOutcome)
        assertEquals(0, result.consecutiveFailures)
        assertTrue(result.runtime.logWriteError)
    }

    @Test fun should_retryMissingLogAndKeepStateConsistent_when_storageRecovers() {
        val context = context()
        val store = ScheduledTaskStore(context)
        store.upsert(task())
        val home = File(context.filesDir, "minis-global/home").also { it.mkdirs() }
        val conflict = File(home, "logs").also { it.writeText("fixture path conflict") }
        ScheduledRunRecorder.record(context, store, "task", run("first"), null, details())
        conflict.delete()
        ScheduledRunRecorder.record(context, store, "task", run("second"), null, details())
        val result = store.get("task")!!
        assertFalse(result.runtime.logWriteError)
        val rows = ScheduledRunRecorder.journal(context).query("task").getJSONArray("runs")
        assertEquals(2, rows.length())
        val state = JSONObject(File(home, "state/scheduled/task.json").readText())
        assertEquals(result.consecutiveFailures, state.getInt("consecutive_failures"))
        assertFalse(state.getBoolean("log_write_error"))
    }

    @Test fun should_settleSavedReceiptOnce_withoutReexecutingBusiness() {
        val context = context()
        val store = ScheduledTaskStore(context)
        store.upsert(task())
        val result = run("recover").copy(ok = false, outcome = "failure", status = "execution_failed", exitCode = 7)
        val journal = ScheduledRunRecorder.journal(context)
        journal.stageSettlement(JSONObject().put("task_id", "task").put("run", result.toJson())
            .put("reason", "fixture failure").put("details", details()))
        assertEquals(1, journal.settlements().size)
        ScheduledRunRecorder.recover(context)
        ScheduledRunRecorder.recover(context)
        assertEquals(1, store.get("task")!!.consecutiveFailures)
        assertEquals(1, store.get("task")!!.runHistory.size)
        assertEquals(1, journal.query("task").getJSONArray("runs").length())
        assertTrue(journal.settlements().isEmpty())
    }

    @Test fun should_keepFinalRunLogWithoutRevivingState_when_taskDeletedDuringRun() {
        val context = context()
        val store = ScheduledTaskStore(context)
        store.upsert(task())
        store.delete("task")
        ScheduledRunRecorder.record(context, store, "task", run("deleted"), null, details())
        assertNull(store.get("task"))
        assertEquals("ok", ScheduledRunRecorder.journal(context).query("task").getString("status"))
        assertFalse(File(context.filesDir, "minis-global/home/state/scheduled/task.json").exists())
    }

    @Test fun should_notRecountUnacknowledgedRun_when_historyHasRotated() {
        val context = context()
        val store = ScheduledTaskStore(context)
        val old = run("unacknowledged").copy(ok = false, outcome = "failure")
        val newer = run("latest")
        store.upsert(task().copy(consecutiveFailures = 3, totalFailures = 3, runHistory = listOf(newer),
            runtime = ScheduledRuntime(lastOutcome = "success", settledUnackedRunIds = setOf(old.runId!!))))
        ScheduledRunRecorder.journal(context).stageSettlement(JSONObject().put("task_id", "task").put("run", old.toJson())
            .put("reason", "old failure").put("details", details()))
        ScheduledRunRecorder.recover(context)
        val saved = store.get("task")!!
        assertEquals(3, saved.totalFailures)
        assertEquals(3, saved.consecutiveFailures)
        assertEquals("latest", saved.runHistory.first().runId)
        assertEquals("success", saved.runtime.lastOutcome)
        assertTrue(saved.runtime.settledUnackedRunIds.isEmpty())
    }

    @Test fun should_expireDeletedTaskLogsOnWake_withoutRecreatingTaskState() {
        val context = context()
        val home = File(context.filesDir, "minis-global/home")
        val directory = File(home, "logs/scheduled/deleted-task").also { it.mkdirs() }
        val expired = File(directory, "2000-01-01.jsonl").also { it.writeText("{}\n") }
        val unrelated = File(home, "logs/unrelated.txt").also { it.writeText("keep") }
        ScheduledRunRecorder.recover(context)
        assertFalse(expired.exists())
        assertEquals("keep", unrelated.readText())
        assertFalse(File(home, "state/scheduled/deleted-task.json").exists())
    }
}
