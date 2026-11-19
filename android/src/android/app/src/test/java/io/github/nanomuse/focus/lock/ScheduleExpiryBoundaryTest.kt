package io.github.nanomuse.focus.lock

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test
import java.time.LocalDate
import java.time.ZoneId

/** 验证计划结束边界、连续区间和跨天展开，不依赖Android调度。 */
class ScheduleExpiryBoundaryTest {
    private val zone = ZoneId.of("Asia/Shanghai")
    private val monday = LocalDate.of(2026, 9, 7)

    /** 结束前一毫秒仍活动，结束瞬间必须空闲。 */
    @Test
    fun should_endAtExactBoundary_when_singleIntervalExpires() {
        val plans = listOf(plan("single", 480, 540))
        assertNotNull(LockPlanEvaluator.activeWindow(plans, at(monday, 9) - 1L, zone = zone))
        assertNull(LockPlanEvaluator.activeWindow(plans, at(monday, 9), zone = zone))
    }

    /** 相邻计划交接时，上一段完成身份不能屏蔽下一段。 */
    @Test
    fun should_selectAdjacentInterval_when_previousIntervalEnds() {
        val plans = listOf(plan("first", 480, 540), plan("second", 540, 600))
        val completed = active(plans, at(monday, 8)).occurrenceIds
        val next = active(plans, at(monday, 9), completed)
        assertEquals(setOf("second"), next.planIds)
        assertEquals(at(monday, 10), next.endAt)
        assertEquals(setOf("occ:v1:6:second:2026-09-07:540:600"), next.occurrenceIds)
    }

    /** 一分钟真实空档不能被前一段填平。 */
    @Test
    fun should_remainIdleDuringGap_when_nextIntervalStartsLater() {
        val plans = listOf(plan("first", 480, 540), plan("later", 541, 600))
        val completed = active(plans, at(monday, 8)).occurrenceIds
        assertNull(LockPlanEvaluator.activeWindow(plans, at(monday, 9), completed, zone))
        val next = LockPlanEvaluator.nextWindow(plans, at(monday, 9), zone)
        assertNotNull(next)
        assertEquals(at(monday, 9, 1), next!!.start)
    }

    /** 重叠链逐段结算完成身份，最后一个结束点之后保持空闲。 */
    @Test
    fun should_finishAfterLastOverlap_when_intervalsFormAContinuousChain() {
        val plans = listOf(plan("first", 480, 600), plan("second", 540, 660),
            plan("third", 630, 720))
        val completed = mutableSetOf<String>()
        val first = active(plans, at(monday, 8), completed)
        assertEquals(at(monday, 10), first.endAt)
        completed.addAll(first.occurrenceIds)
        val second = active(plans, at(monday, 10), completed)
        assertEquals(at(monday, 11), second.endAt)
        completed.addAll(second.occurrenceIds)
        val third = active(plans, at(monday, 11), completed)
        assertEquals(at(monday, 12), third.endAt)
        completed.addAll(third.occurrenceIds)
        assertNull(LockPlanEvaluator.activeWindow(plans, at(monday, 12), completed, zone))
    }

    /** 跨午夜计划在次日结束时不能多延长一天。 */
    @Test
    fun should_endOnNextDay_when_overnightIntervalReachesBoundary() {
        val plans = listOf(plan("overnight", 1380, 30))
        val nextDay = monday.plusDays(1)
        assertEquals(at(nextDay, 0, 30), active(plans, at(nextDay, 0, 29)).endAt)
        assertNull(LockPlanEvaluator.activeWindow(plans, at(nextDay, 0, 30), zone = zone))
    }

    /** 完成身份排除回拨后的同一日历区间。 */
    @Test
    fun should_excludeCompletedInterval_when_wallClockReturnsInsideIt() {
        val plans = listOf(plan("completed", 480, 540))
        val completed = active(plans, at(monday, 8)).occurrenceIds
        assertNull(LockPlanEvaluator.activeWindow(plans, at(monday, 8, 30), completed, zone))
    }

    private fun active(
        plans: List<LockPlan>, now: Long, completed: Set<String> = emptySet()
    ): LockWindow {
        val window = LockPlanEvaluator.activeWindow(plans, now, completed, zone)
        assertNotNull("边界前应有活动窗口", window)
        return window!!
    }

    private fun plan(id: String, startMinute: Int, endMinute: Int) = LockPlan(
        id, id, setOf(1), listOf(TimeRange(startMinute, endMinute))
    )

    private fun at(date: LocalDate, hour: Int, minute: Int = 0): Long =
        date.atTime(hour, minute).atZone(zone).toInstant().toEpochMilli()
}
