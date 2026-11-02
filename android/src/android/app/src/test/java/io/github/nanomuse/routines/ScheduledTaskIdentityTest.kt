package io.github.nanomuse.routines

import com.openminis.app.scheduled.*
import org.junit.Assert.*
import org.junit.Test

/** 判重不依赖标题截断，也不误伤不同追加目标。 */
class ScheduledTaskIdentityTest {
    private val task = ScheduledTask(label = "读书", timeOfDayHour = 9, timeOfDayMinute = 0, prompt = "总结", repeatMode = ScheduledRepeatMode.DAILY)
    @Test fun should_match_when_onlyIdAndWhitespaceDiffer() { assertTrue(ScheduledTaskIdentity.same(task, task.copy(id = "another", label = " 读书 "))) }
    @Test fun should_differ_when_targetOrTimesDiffer() {
        assertFalse(ScheduledTaskIdentity.same(task, task.copy(additionalTimes = listOf(14 to 0))))
        assertFalse(ScheduledTaskIdentity.same(task, task.copy(targetMode = ScheduledTargetMode.AppendToSession("other"))))
        assertFalse(ScheduledTaskIdentity.same(task, task.copy(prompt = "不同内容")))
    }
    @Test fun should_preserveMetadata_when_jsonRoundTrip() {
        val saved = task.copy(scriptId = "daily.sh", consecutiveFailures = 2, totalFailures = 3, autoDisableOnFailure = false)
        assertEquals(saved, ScheduledTask.fromJson(saved.toJson()))
        val run = ScheduledRun(1234, "session", "failed", false, startedAtMs = 1200, durationMs = 34, status = "execution_failed", exitCode = 5)
        assertEquals(run, ScheduledRun.fromJson(run.toJson()))
    }
    @Test fun should_defaultToWarnOnly_when_oldTaskLoaded() { assertFalse(ScheduledTask.fromJson(task.toJson()).autoDisableOnFailure) }
    @Test fun should_rejectTraversal_when_scriptCommandRequested() { assertThrows(IllegalArgumentException::class.java) { ScheduledScript.command("../private.sh") } }
    @Test fun should_askApproval_when_scriptDeletesOrSends() {
        assertTrue(ScheduledScript.assessment("daily.sh", "rm -rf /var/minis/home/state").needsApproval)
        assertTrue(ScheduledScript.assessment("daily.py", "import requests\nrequests.post('https://example.invalid', data='fixture')").needsApproval)
    }
}
