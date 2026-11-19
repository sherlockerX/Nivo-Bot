package io.github.nanomuse.records

import com.openminis.app.scheduled.ScheduledRepeatMode
import com.openminis.app.scheduled.ScheduledRun
import com.openminis.app.scheduled.ScheduledTask
import com.openminis.app.tools.ToolExecutionResult
import io.github.nanomuse.goals.Goal
import io.github.nanomuse.goals.GoalStep
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

/** 验证真正工具入口的数据边界、分页、完整正文与撤销授权后的返回行为。 */
class PersonalRecordsAgentBridgeTest {
    @Test fun should_discoverSourcesWithoutReadingHistory_when_catalogRequested() = runBlocking {
        val source = FakeSource()
        val result = PersonalRecordsAgentBridge(source) {}.execute("{}")
        assertTrue(result.success)
        assertTrue(result.output.contains("focus_query"))
        assertTrue(result.output.contains("reflection_range"))
        assertTrue(result.output.contains("device_local"))
        assertEquals(0, source.reads)
    }

    @Test fun should_rejectUnsupportedAndMistypedParameters_beforeStorageRead() = runBlocking {
        val source = FakeSource()
        val bridge = PersonalRecordsAgentBridge(source) {}
        val invalid = listOf("[]", "{\"kind\":\"delete\"}", "{\"path\":\"private\"}",
            "{\"kind\":\"goals\",\"startDate\":\"2026-11-16\"}", "{\"limit\":\"20\"}",
            "{\"limit\":0}", "{\"limit\":31}", "{\"offset\":-1}",
            "{\"kind\":\"coach\",\"targetId\":\"course-1\"}",
            "{\"kind\":\"goals\",\"targetId\":\"../../secret\"}",
            "{\"kind\":\"routines\",\"section\":\"courses\"}")
        invalid.forEach { assertFalse(it, bridge.execute(it).success) }
        assertEquals(0, source.reads)
    }

    @Test fun should_pageGoalSummariesAndPreserveFullDetail_when_selectedByExactId() = runBlocking {
        val source = FakeSource().apply {
            savedGoals = listOf(Goal(id = "older", title = "旧目标", createdAt = 1),
                Goal(id = "newer", title = "新目标", why = "原因".repeat(200), createdAt = 2,
                    steps = listOf(GoalStep("完成真实步骤", false)), lastNote = "保留原话"))
        }
        val bridge = PersonalRecordsAgentBridge(source) {}
        val first = data(bridge.execute("{\"kind\":\"goals\",\"limit\":1}"))
        assertEquals(2, first.getInt("total"))
        assertEquals("newer", first.getJSONArray("items").getJSONObject(0).getString("id"))
        assertEquals(1, first.getInt("nextOffset"))
        val next = data(bridge.execute("{\"kind\":\"goals\",\"limit\":1,\"offset\":1}"))
        assertEquals("older", next.getJSONArray("items").getJSONObject(0).getString("id"))
        assertTrue(next.isNull("nextOffset"))
        val detail = data(bridge.execute("{\"kind\":\"goals\",\"targetId\":\"newer\"}"))
        assertEquals("原因".repeat(200), detail.getString("why"))
        assertFalse(detail.getJSONArray("steps").getJSONObject(0).getBoolean("done"))
        assertFalse(bridge.execute("{\"kind\":\"goals\",\"targetId\":\"missing\"}").success)
    }

    @Test fun should_pageActualRetainedRuns_when_routineDetailRequested() = runBlocking {
        val source = FakeSource().apply { savedRoutines = listOf(ScheduledTask(id = "routine-1", label = "回顾",
            timeOfDayHour = 9, timeOfDayMinute = 30, repeatMode = ScheduledRepeatMode.DAILY,
            prompt = "阅读本周记录", runHistory = listOf(
                ScheduledRun(10, "chat-1", "第一次", true),
                ScheduledRun(20, "chat-2", "失败原文", false)))) }
        val result = data(PersonalRecordsAgentBridge(source) {}
            .execute("{\"kind\":\"routines\",\"targetId\":\"routine-1\",\"limit\":1}"))
        assertEquals("阅读本周记录", result.getString("prompt"))
        assertEquals("retained_on_device", result.getString("historyScope"))
        val runs = result.getJSONObject("runs")
        assertEquals(1, runs.getInt("nextOffset"))
        assertEquals("失败原文", runs.getJSONArray("items").getJSONObject(0).getString("preview"))
        assertFalse(runs.getJSONArray("items").getJSONObject(0).getBoolean("ok"))
    }

    @Test fun should_preserveDiaryProtocolAndExactDates_when_reflectionsRequested() = runBlocking {
        val source = FakeSource()
        val bridge = PersonalRecordsAgentBridge(source) {}
        assertTrue(bridge.execute("{\"kind\":\"reflections\",\"startDate\":\"2026-10-01\",\"endDate\":\"2026-10-31\",\"limit\":10,\"offset\":10}").success)
        assertEquals(listOf("list", "--start", "2026-10-01", "--end", "2026-10-31", "--limit", "10", "--offset", "10"), source.diaryArguments)
        assertTrue(bridge.execute("{\"kind\":\"reflection_stats\"}").success)
        assertEquals(listOf("stats"), source.diaryArguments)
    }

    @Test fun should_delegateOnlyCoachQuery_when_historyRequested() = runBlocking {
        val source = FakeSource()
        val result = PersonalRecordsAgentBridge(source) {}
            .execute("{\"kind\":\"coach\",\"section\":\"sessions\",\"targetId\":\"lesson-1\"}")
        assertTrue(result.success)
        val arguments = JSONObject(source.coachArguments)
        assertEquals("sessions", arguments.getString("kind"))
        assertEquals("lesson-1", arguments.getString("targetId"))
        assertFalse(arguments.has("action"))
    }

    @Test fun should_reportStorageFailureInsteadOfEmpty_when_archiveUnavailable() = runBlocking {
        val source = FakeSource().apply { shouldFail = true }
        val result = PersonalRecordsAgentBridge(source) {}.execute("{\"kind\":\"goals\"}")
        assertFalse(result.success)
        assertEquals("records_unavailable", JSONObject(result.output).getString("code"))
        assertFalse(result.output.contains("\"status\":\"empty\""))
    }

    @Test fun should_notReturnReadData_when_authorizationChangesDuringRead() = runBlocking {
        var isAllowed = true
        val source = FakeSource().apply { onRead = { isAllowed = false } }
        val result = PersonalRecordsAgentBridge(source) { check(isAllowed) { "authorization_changed" } }
            .execute("{\"kind\":\"goals\"}")
        assertFalse(result.success)
        assertTrue(result.output.contains("authorization_changed"))
        assertFalse(result.output.contains("private-goal"))
    }

    @Test fun should_propagateCancellation_beforeReadingAnyRecord() = runBlocking {
        val source = FakeSource()
        try {
            PersonalRecordsAgentBridge(source) { throw CancellationException("cancelled") }.execute("{\"kind\":\"goals\"}")
            fail("取消必须传播")
        } catch (_: CancellationException) { assertEquals(0, source.reads) }
    }

    @Test fun should_rejectOversizedOutputWithoutTruncation_when_oneDetailIsTooLarge() = runBlocking {
        val source = FakeSource().apply { savedGoals = listOf(Goal(id = "large", title = "large", why = "文".repeat(800_000))) }
        val result = PersonalRecordsAgentBridge(source) {}.execute("{\"kind\":\"goals\",\"targetId\":\"large\"}")
        assertFalse(result.success)
        assertTrue(result.output.contains("No record text was truncated"))
    }

    @Test fun should_rejectCorruptSavedRows_withoutCreatingAnIdOrReturningEmpty() {
        listOf("invalid", "[null]", "[{}]", "[{\"title\":\"missing id\"}]").forEach { raw ->
            assertTrue(raw, runCatching { PersonalRecordDecoding.goals(raw) }.isFailure)
            assertTrue(raw, runCatching { PersonalRecordDecoding.routines(raw) }.isFailure)
        }
        assertTrue(PersonalRecordDecoding.goals("[]").isEmpty())
    }

    @Test fun should_rejectMissingRunEvidence_andCorruptChildRows() {
        listOf("null", "{}", "{\"firedAt\":1}", "{\"ok\":true}",
            "{\"firedAt\":1,\"ok\":\"true\"}").forEach { child ->
            val raw = "[{\"id\":\"r1\",\"runHistory\":[$child]}]"
            assertTrue(raw, runCatching { PersonalRecordDecoding.routines(raw) }.isFailure)
        }
        listOf("[null]", "[{}]", "false", "[{\"text\":\"x\",\"done\":\"true\"}]").forEach { steps ->
            assertTrue(runCatching { PersonalRecordDecoding.goals("[{\"id\":\"g1\",\"steps\":$steps}]") }.isFailure)
        }
    }

    @Test fun should_preserveFailedRuns_andLeaveMissingHistoricalTimeUnknown() {
        val goals = PersonalRecordDecoding.goals("[{\"id\":\"g1\",\"title\":\"旧目标\"}]")
        assertEquals(0L, goals.single().createdAt)
        val tasks = PersonalRecordDecoding.routines("[{\"id\":\"r1\",\"runHistory\":[{\"firedAt\":10,\"ok\":false}]}]")
        assertEquals(0L, tasks.single().createdAt)
        assertFalse(tasks.single().runHistory.single().ok)
        assertEquals("execution_failed", tasks.single().runHistory.single().status)
    }

    private fun data(result: ToolExecutionResult): JSONObject {
        assertTrue(result.output, result.success)
        return JSONObject(result.output).getJSONObject("data")
    }

    /** 仅替换存储端口，工具校验、分页及权限复核均运行真实实现。 */
    private class FakeSource : PersonalRecordSource {
        var reads = 0
        var shouldFail = false
        var onRead: () -> Unit = {}
        var savedGoals = listOf(Goal(id = "private-goal", title = "私有目标"))
        var savedRoutines = emptyList<ScheduledTask>()
        var diaryArguments = emptyList<String>()
        var coachArguments = "{}"
        private fun beforeRead() { reads++; onRead(); check(!shouldFail) { "storage unavailable" } }
        override suspend fun reflections(arguments: List<String>): ToolExecutionResult {
            beforeRead(); diaryArguments = arguments
            return ToolExecutionResult("{\"success\":true}", true)
        }
        override suspend fun reflectionRange(): JSONObject { beforeRead(); return JSONObject() }
        override suspend fun coach(arguments: String): ToolExecutionResult {
            beforeRead(); coachArguments = arguments
            return ToolExecutionResult("{\"success\":true}", true)
        }
        override suspend fun goals(): List<Goal> { beforeRead(); return savedGoals }
        override suspend fun routines(): List<ScheduledTask> { beforeRead(); return savedRoutines }
    }
}
