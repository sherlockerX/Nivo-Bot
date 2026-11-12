package io.github.nanomuse.routines

import com.openminis.app.scheduled.*
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.test.runTest
import org.junit.Assert.*
import org.junit.Test

/** 运行结果、参数和自报上下文的回归，不请求模型。 */
@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
class ScheduledRunBehaviorTest {
    private fun task() = ScheduledTask(label = "fixture", timeOfDayHour = 6, timeOfDayMinute = 0,
        repeatMode = ScheduledRepeatMode.DAILY, prompt = "offline", consecutiveFailures = 2, totalFailures = 4)

    @Test fun should_notResetFailures_when_outcomeIsUnknown() {
        val result = ScheduledRunRecorder.reduce(task(), ScheduledRun(50, null, null, true, outcome = "unknown"), null)
        assertEquals(2, result.consecutiveFailures)
        assertEquals(4, result.totalFailures)
        assertEquals(1, result.runtime.unknownRuns)
    }

    @Test fun should_disableAtThreshold_when_confirmedFailuresRepeat() {
        var current = task().copy(consecutiveFailures = 0, totalFailures = 0, autoDisableOnFailure = true)
        repeat(5) { index -> current = ScheduledRunRecorder.reduce(current,
            ScheduledRun(index + 1L, null, null, false, outcome = "failure"), "fixture failure") }
        assertFalse(current.enabled)
        assertEquals(5, current.consecutiveFailures)
        assertEquals(5, current.totalFailures)
        assertEquals(5L, current.runtime.autoDisabledAtMs)
        val successful = ScheduledRunRecorder.reduce(current, ScheduledRun(7, null, null, true, outcome = "success"), null)
        assertEquals(0, successful.consecutiveFailures)
        assertFalse(successful.enabled)
    }

    @Test fun should_groupVisibleUserAndLegacyTasks_withoutAdoptingBuiltinsOrUnknownOrigins() {
        listOf("legacy", "user_ui", "user_cli", "user_idea").forEach { origin ->
            assertTrue(ScheduledConversationGroup.isUserTask(task().copy(origin = origin)))
            assertFalse(ScheduledConversationGroup.isUserTask(task().copy(origin = origin, hidden = true)))
            assertFalse(ScheduledConversationGroup.isUserTask(task().copy(origin = origin, goalId = "goal")))
        }
        listOf("builtin_feed", "builtin_goal", "unknown", "").forEach { origin ->
            assertFalse(ScheduledConversationGroup.isUserTask(task().copy(origin = origin)))
        }
        val oldJson = task().toJson().apply { remove("origin") }
        assertTrue(ScheduledConversationGroup.isUserTask(ScheduledTask.fromJson(oldJson)))
    }

    @Test fun should_preserveLiteralArguments_when_buildingArgv() {
        val arguments = listOf("am", "a b; rm -rf /", "'\"$`", "")
        assertEquals(listOf("/usr/bin/python3", "/var/minis/home/bin/fixture.py") + arguments,
            ScheduledProcess.argv("fixture.py", arguments))
    }

    @Test fun should_rejectUnsafeArgumentsAndPaths_when_invalid() {
        listOf(List(17) { "x" }, listOf("x".repeat(257)), listOf("a\u0000b"), listOf("文".repeat(86))).forEach { arguments ->
            assertThrows(IllegalArgumentException::class.java) { ScheduledProcess.argv("fixture.sh", arguments) }
        }
        listOf("../x.sh", "a/b.sh", "a..b.sh", "fixture.exe").forEach { name ->
            assertThrows(IllegalArgumentException::class.java) { ScheduledProcess.argv(name, emptyList()) }
        }
    }

    @Test fun should_useLastReportOnlyInsideBoundRun_when_reporting() {
        val scope = ScheduledRunScope("task")
        scope.registerProcess(123)
        assertTrue(ScheduledRunScopes.enter("fixture", scope))
        try {
            ScheduledRunScopes.report("fixture", scope.environment(), "failure", "first", 123)
            ScheduledRunScopes.report("fixture", scope.environment(), "success", "second", 123)
            assertThrows(IllegalArgumentException::class.java) { ScheduledRunScopes.report("fixture", scope.environment(), "success", null, 124) }
            assertEquals(RunOutcome.SUCCESS, ScheduledRunScopes.outcome(scope, false, null, false))
            assertEquals(RunOutcome.FAILURE, ScheduledRunScopes.outcome(scope, true, null, false))
            assertThrows(IllegalArgumentException::class.java) { ScheduledRunScopes.report("other", scope.environment(), "failure", null) }
            assertThrows(IllegalArgumentException::class.java) { ScheduledRunScopes.report("fixture", emptyMap(), "failure", null) }
        } finally { ScheduledRunScopes.leave("fixture", scope) }
        assertThrows(IllegalArgumentException::class.java) { ScheduledRunScopes.report("fixture", scope.environment(), "success", null) }
    }

    @Test fun should_retryThreeTimesWithSameOperation_when_messageWriteFails() = runTest {
        var calls = 0
        val result = ScheduledOutputWriter.retryWrite { calls++; if (calls < 4) error("fixture failure"); "saved" }
        assertEquals("saved", result)
        assertEquals(4, calls)
        assertEquals(4200L, testScheduler.currentTime)
    }

    @Test fun should_failExplicitlyWithoutRetryingCancellation_when_writeCannotComplete() = runTest {
        var calls = 0
        try { ScheduledOutputWriter.retryWrite { calls++; error("fixture failure") }; fail("expected failure") }
        catch (failure: IllegalStateException) { assertEquals("MESSAGE_WRITE_FAILED", failure.message) }
        assertEquals(4, calls)
        calls = 0
        try { ScheduledOutputWriter.retryWrite { calls++; throw CancellationException("fixture") }; fail("expected cancellation") }
        catch (_: CancellationException) { assertEquals(1, calls) }
    }
}
