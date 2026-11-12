package io.github.nanomuse.todo

import java.time.LocalDate
import org.junit.Assert.*
import org.junit.Test

/** 状态和统计的业务回归，不依赖界面或真实用户数据。 */
class TodoRulesTest {
    private val day = LocalDate.of(2026, 11, 9).toEpochDay()

    @Test fun should_preserveCompletionSnapshot_when_doneTaskTagsChange() {
        val task = TodoTask(ownerKey = "a", title = "阅读", tagsJson = todoTagsJson(listOf("成长")))
        val done = TodoRules.update(task, null, "a", "id", 10, day)
        val completed = TodoRules.update(done.copy(status = "done"), done, "a", "id", 20, day)
        val edited = TodoRules.update(completed.copy(tagsJson = "[\"工作\"]"), completed, "a", "id", 30, day)
        assertEquals("[\"成长\"]", edited.completionTagsJson)
        assertEquals(20L, edited.completedAt)
    }

    @Test fun should_clearCompletion_when_taskReopens() {
        val task = TodoTask(ownerKey = "a", id = "id", title = "阅读", status = "done",
            completedDay = day, completedAt = 20, completionTagsJson = "[\"成长\"]")
        val reopened = TodoRules.update(task.copy(status = "in_progress"), task, "a", "id", 30, day)
        assertNull(reopened.completedDay)
        assertNull(reopened.completedAt)
        assertEquals("[]", reopened.completionTagsJson)
    }

    @Test fun should_splitOneWeightPerTask_when_tasksHaveMultipleTags() {
        val task = TodoTask(ownerKey = "a", id = "1", title = "写作", status = "done",
            completedDay = day, completionTagsJson = "[\"工作\",\"成长\"]")
        val second = task.copy(id = "2", completionTagsJson = "[\"工作\"]")
        val excluded = task.copy(id = "3", deletedAt = 3)
        val result = TodoStatistics.calculate(listOf(task, second, excluded), day, day + 1)
        assertEquals(2, result.completedCount)
        assertEquals(75.0, result.slices.first { it.tag == "工作" }.percentage, .001)
        assertEquals(2, result.slices.first { it.tag == "工作" }.taskCount)
        assertEquals(100.0, result.slices.sumOf { it.percentage }, .001)
        assertEquals(0, TodoStatistics.calculate(listOf(task), day + 1, day + 2).completedCount)
    }

    @Test fun should_rejectWrongOwnerAndInvalidState() {
        val task = TodoTask(ownerKey = "b", title = "阅读")
        assertThrows(IllegalArgumentException::class.java) { TodoRules.update(task, null, "a", "id", 1, day) }
        assertThrows(IllegalArgumentException::class.java) {
            TodoRules.update(task.copy(ownerKey = "a", status = "unknown"), null, "a", "id", 1, day)
        }
    }

    @Test fun should_keepCalendarBoundariesAndUntaggedWeight() {
        val start = LocalDate.of(2026, 12, 28).toEpochDay()
        val end = LocalDate.of(2027, 1, 4).toEpochDay()
        val base = TodoTask(ownerKey = "a", id = "1", title = "跨年", status = "done", completedDay = end - 1)
        val tasks = listOf(base, base.copy(id = "2", completedDay = end), base.copy(id = "3", status = "in_progress"))
        val week = TodoStatistics.calculate(tasks, start, end)
        assertEquals(1, week.completedCount)
        assertEquals("", week.slices.single().tag)
        assertEquals(100.0, week.slices.single().percentage, .001)
        val yearEnd = LocalDate.of(2027, 1, 1).toEpochDay()
        assertEquals(0, TodoStatistics.calculate(tasks, LocalDate.of(2026, 1, 1).toEpochDay(), yearEnd).completedCount)
    }

    @Test fun should_rejectFutureCompletionAndDeduplicateTags() {
        assertEquals(listOf("成长", "工作"), parseTodoTags("[\" 成长 \",\"工作\",\"成长\",\"\"]"))
        val task = TodoTask(ownerKey = "a", title = "未来", status = "done", completedDay = day + 1)
        assertThrows(IllegalArgumentException::class.java) { TodoRules.update(task, null, "a", "id", 1, day) }
    }
}
