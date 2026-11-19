package io.github.nanomuse.focus.lock

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test
import java.time.LocalDate
import java.time.ZoneId

/** 验证同一日历计划的身份不依赖时区，并隔离不同计划、日期和时段。 */
class ScheduleOccurrenceTest {
    private val monday = LocalDate.of(2026, 9, 7)
    private val shanghai = ZoneId.of("Asia/Shanghai")
    private val bangkok = ZoneId.of("Asia/Bangkok")

    /** 上海会话结束后切换到曼谷，同一周一时段不能重新执行。 */
    @Test
    fun should_skipCompletedOccurrence_when_timezoneMovesItsEpochStart() {
        val plans = listOf(schedule("morning", 480, 540))
        val initial = LockPlanEvaluator.activeWindow(plans, at(monday, 8, shanghai), zone = shanghai).requiredValue()
        val replay = LockPlanEvaluator.activeWindow(
            plans, initial.endAt, zone = bangkok,
            excludeOccurrenceIds = initial.occurrenceIds
        )
        assertNull(replay)
    }

    /** 相同计划、原定日期和时段在不同时区仍使用同一稳定身份。 */
    @Test
    fun should_keepOccurrenceId_when_timezoneChanges() {
        val plans = listOf(schedule("morning", 480, 540))
        val first = LockPlanEvaluator.activeWindow(plans, at(monday, 8, shanghai), zone = shanghai).requiredValue()
        val second = LockPlanEvaluator.activeWindow(plans, at(monday, 8, bangkok), zone = bangkok).requiredValue()
        assertEquals(1, first.occurrenceIds.size)
        assertEquals(first.occurrenceIds, second.occurrenceIds)
        assertNotEquals(first.startAt, second.startAt)
    }

    /** 新完成身份不能屏蔽相同开始epoch但属于其他计划的时段。 */
    @Test
    fun should_allowDifferentSchedule_when_startEpochMatchesCompletedOccurrence() {
        val first = LockPlanEvaluator.activeWindow(
            listOf(schedule("first", 480, 540)), at(monday, 8, shanghai), zone = shanghai
        ).requiredValue()
        val replacement = LockPlanEvaluator.activeWindow(
            listOf(schedule("different", 480, 600)), at(monday, 9, shanghai),
            zone = shanghai, excludeOccurrenceIds = first.occurrenceIds
        )
        assertNotNull(replacement)
        assertEquals(setOf("different"), replacement.requiredValue().planIds)
    }

    /** 次日或次周是新一次计划，不能被上一周的完成身份抹去。 */
    @Test
    fun should_allowNextWeek_when_previousOccurrenceCompleted() {
        val plans = listOf(schedule("weekly", 480, 540))
        val first = LockPlanEvaluator.activeWindow(plans, at(monday, 8, shanghai), zone = shanghai).requiredValue()
        val next = LockPlanEvaluator.activeWindow(
            plans, at(monday.plusWeeks(1), 8, bangkok), zone = bangkok,
            excludeOccurrenceIds = first.occurrenceIds
        )
        assertNotNull(next)
        assertNotEquals(first.occurrenceIds, next.requiredValue().occurrenceIds)
    }

    /** 时段的结束分钟也是身份的一部分，编辑成新时段不会沿用旧完成标记。 */
    @Test
    fun should_allowEditedRange_when_endMinuteChanges() {
        val first = LockPlanEvaluator.activeWindow(
            listOf(schedule("edited", 480, 540)), at(monday, 8, shanghai), zone = shanghai
        ).requiredValue()
        val edited = LockPlanEvaluator.activeWindow(
            listOf(schedule("edited", 480, 600)), at(monday, 9, shanghai), zone = shanghai,
            excludeOccurrenceIds = first.occurrenceIds
        )
        assertNotNull(edited)
    }

    /** 区间身份采用原定开始日期，跨午夜后与时区变化仍不重放。 */
    @Test
    fun should_skipOvernightReplay_when_timezoneChangesAfterMidnight() {
        val plans = listOf(schedule("overnight", 23 * 60, 60))
        val original = LockPlanEvaluator.activeWindow(plans, at(monday, 23, shanghai), zone = shanghai).requiredValue()
        assertNull(LockPlanEvaluator.activeWindow(
            plans, original.endAt, zone = bangkok, excludeOccurrenceIds = original.occurrenceIds
        ))
    }

    /** 未来开始查询也排除已完成身份，避免回拨后反复排同一开始闹钟。 */
    @Test
    fun should_findFollowingWeek_when_completedOccurrenceBecomesFutureAfterRollback() {
        val plans = listOf(schedule("weekly", 480, 540))
        val original = LockPlanEvaluator.activeWindow(plans, at(monday, 8, shanghai), zone = shanghai).requiredValue()
        val next = LockPlanEvaluator.nextWindow(
            plans, at(monday, 7, bangkok), bangkok,
            excludeOccurrenceIds = original.occurrenceIds
        ).requiredValue()
        assertEquals(at(monday.plusWeeks(1), 8, bangkok), next.start)
    }

    /** 不同字段中的分隔符不能造成身份拼接碰撞。 */
    @Test
    fun should_keepDistinctIds_when_scheduleIdContainsSeparators() {
        val first = LockPlanEvaluator.activeWindow(
            listOf(schedule("a:2026-09-07:480:540", 480, 540)),
            at(monday, 8, shanghai), zone = shanghai
        ).requiredValue()
        val second = LockPlanEvaluator.activeWindow(
            listOf(schedule("a", 480, 540)), at(monday, 8, shanghai), zone = shanghai
        ).requiredValue()
        assertNotEquals(first.occurrenceIds, second.occurrenceIds)
    }

    private fun schedule(id: String, start: Int, end: Int): LockPlan = LockPlan(
        id = id, name = id, days = setOf(1), ranges = listOf(TimeRange(start, end))
    )

    private fun at(date: LocalDate, hour: Int, zone: ZoneId): Long =
        date.atTime(hour, 0).atZone(zone).toInstant().toEpochMilli()

    private fun <T : Any> T?.requiredValue(): T {
        assertNotNull("评估结果不应为空", this)
        return this!!
    }
}
