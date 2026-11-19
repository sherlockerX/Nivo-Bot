package io.github.nanomuse.focus

import io.github.nanomuse.todo.TodoTask
import org.junit.Assert.assertEquals
import org.junit.Test
import java.time.LocalDate
import java.time.ZoneOffset

/** 专注统计沿用待办分组：比重按真实计时区间计算，分组以任务当前所在分组为准。 */
class FocusGroupStatisticsTest {
    private val zone = ZoneOffset.UTC
    private val day = LocalDate.of(2026, 11, 17)
    private val dayStart = day.atStartOfDay(zone).toInstant().toEpochMilli()
    private val minute = 60_000L

    @Test fun should_splitTimeByCurrentTodoGroup_when_tasksMoveBetweenGroups() {
        val tasks = listOf(task("t1", "Read", "Study"), task("t2", "Gym", "Health"))
        // t1开始时在旧分组，之后被移到Study；统计以当前分组为准。
        val sessions = listOf(session("s1", "t1", group = "Old"), session("s2", "t2"), session("s3", "t1"))
        val spans = listOf(span("s1", 0, 30), span("s2", 60, 10), span("s3", 120, 20))
        val result = FocusGroupStatistics.calculate(sessions, spans, tasks, day, day.plusDays(1), zone)
        assertEquals(60 * minute, result.totalMs)
        assertEquals(3, result.sessionCount)
        assertEquals(listOf("Study", "Health"), result.groups.map { it.group })
        assertEquals(50 * minute, result.groups[0].durationMs)
        assertEquals(83.33, result.groups[0].percentage, 0.01)
        assertEquals(listOf(FocusTaskShare("t1", "Read", 50 * minute, 2)), result.groups[0].tasks)
        assertEquals(20 * minute, result.averageMs)
    }

    @Test fun should_useSnapshot_when_taskWasDeleted() {
        val deleted = task("t1", "Gone", "Study").copy(deletedAt = 1)
        val sessions = listOf(session("s1", "t1", group = "Archive", title = "Old title"))
        val result = FocusGroupStatistics.calculate(sessions, listOf(span("s1", 0, 10)), listOf(deleted), day, day.plusDays(1), zone)
        assertEquals("Archive", result.groups.single().group)
        assertEquals(FocusTaskShare(null, "Old title", 10 * minute, 1), result.groups.single().tasks.single())
    }

    @Test fun should_excludeBreaksUnfinishedAndDeletedSessions_when_counting() {
        val sessions = listOf(
            session("break", null, mode = "break"),
            session("running", "t1", status = "running"),
            session("deleted", "t1").copy(deletedAt = 5),
            session("ok", null, group = ""),
        )
        val spans = sessions.map { span(it.id, 0, 10) }
        val result = FocusGroupStatistics.calculate(sessions, spans, emptyList(), day, day.plusDays(1), zone)
        assertEquals(10 * minute, result.totalMs)
        assertEquals(1, result.sessionCount)
        assertEquals("", result.groups.single().group)
        assertEquals(100.0, result.groups.single().percentage, 0.0)
    }

    @Test fun should_countOnlyTheOverlap_when_focusCrossesMidnight() {
        val sessions = listOf(session("s1", "t1"))
        // 23:30开始专注60分钟，当天只算30分钟，第二天算另外30分钟。
        val spans = listOf(span("s1", 23 * 60 + 30, 60))
        val tasks = listOf(task("t1", "Write", "Work"))
        assertEquals(30 * minute, FocusGroupStatistics.calculate(sessions, spans, tasks, day, day.plusDays(1), zone).totalMs)
        assertEquals(30 * minute, FocusGroupStatistics.calculate(sessions, spans, tasks, day.plusDays(1), day.plusDays(2), zone).totalMs)
        assertEquals(0, FocusGroupStatistics.calculate(sessions, spans, tasks, day.plusDays(2), day.plusDays(3), zone).sessionCount)
    }

    @Test fun should_mergeGroupNames_when_theyDifferOnlyBySpaces() {
        val tasks = listOf(task("t1", "A", "Study "), task("t2", "B", "Study"))
        val result = FocusGroupStatistics.calculate(listOf(session("s1", "t1"), session("s2", "t2")),
            listOf(span("s1", 0, 10), span("s2", 20, 10)), tasks, day, day.plusDays(1), zone)
        assertEquals(listOf("Study"), result.groups.map { it.group })
        assertEquals(2, result.groups.single().tasks.size)
    }

    @Test fun should_splitTimeEvenlyAcrossTags_when_viewingByTag() {
        val tasks = listOf(task("t1", "Read", "Study").copy(tagsJson = """["math","exam"]"""),
            task("t2", "Gym", "Health").copy(tagsJson = """["exam"]"""))
        val sessions = listOf(session("s1", "t1"), session("s2", "t2"), session("s3", null))
        val spans = listOf(span("s1", 0, 40), span("s2", 60, 20), span("s3", 120, 20))
        val result = FocusGroupStatistics.calculate(sessions, spans, tasks, day, day.plusDays(1), zone, FocusShareBy.TAG)
        assertEquals(80 * minute, result.totalMs)
        assertEquals(3, result.sessionCount)
        // s1的40分钟平分给math和exam；s3没有任务，算作未标记。
        assertEquals(listOf("exam", "math", ""), result.groups.map { it.group })
        assertEquals(40 * minute, result.groups[0].durationMs)
        assertEquals(2, result.groups[0].sessionCount)
        assertEquals(20 * minute, result.groups[1].durationMs)
        assertEquals(100.0, result.groups.sumOf { it.percentage }, 0.001)
        assertEquals(setOf(FocusTaskShare("t1", "Read", 20 * minute, 1), FocusTaskShare("t2", "Gym", 20 * minute, 1)),
            result.groups[0].tasks.toSet())
    }

    @Test fun should_useTagSnapshot_when_taskWasDeleted() {
        val sessions = listOf(session("s1", "gone").copy(tagsJson = """["old"]"""))
        val result = FocusGroupStatistics.calculate(sessions, listOf(span("s1", 0, 10)), emptyList(), day, day.plusDays(1), zone, FocusShareBy.TAG)
        assertEquals("old", result.groups.single().group)
    }

    private fun task(id: String, title: String, group: String) =
        TodoTask(ownerKey = "me", id = id, title = title, groupName = group)

    private fun session(
        id: String, taskId: String?, group: String = "", title: String = id,
        mode: String = "pomodoro", status: String = "finished",
    ) = FocusSession(ownerKey = "me", id = id, title = title, taskId = taskId, groupName = group, tagsJson = "[]",
        mode = mode, targetMs = 25 * minute, status = status, startedAt = dayStart, updatedAt = dayStart,
        runningWall = dayStart, runningElapsed = 0, bootCount = 1)

    private fun span(sessionId: String, startMinute: Int, minutes: Int) =
        FocusSpan("me", "span-$sessionId-$startMinute", sessionId, dayStart + startMinute * minute, minutes * minute)
}
