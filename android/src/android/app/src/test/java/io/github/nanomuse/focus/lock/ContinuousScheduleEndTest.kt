package io.github.nanomuse.focus.lock

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test
import java.time.LocalDate
import java.time.ZoneId

/** 验证连续计划结束时间只用于展示，不能修改当前会话的计时截止点。 */
class ContinuousScheduleEndTest {
    private val zone = ZoneId.of("Asia/Shanghai")
    private val monday = LocalDate.of(2026, 9, 7)

    /** 没有后续计划时，展示当前单调剩余量映射出来的结束时刻。 */
    @Test
    fun should_returnCurrentEnd_when_noPlansFollow() {
        assertEquals(at(monday, 10), project(emptyList(), at(monday, 8), at(monday, 10)))
    }

    /** 仅处理与当前截止连续的重叠和相邻段，不跨越真实空档。 */
    @Test
    fun should_extendAcrossOverlapAndAdjacency_when_chainHasNoGap() {
        val plans = listOf(plan("overlap", 540, 660), plan("adjacent", 660, 720))
        assertEquals(at(monday, 12), project(plans, at(monday, 8), at(monday, 10)))
    }

    /** 计划列表顺序不能改变投影的终点。 */
    @Test
    fun should_sortIntervals_when_laterPlanAppearsFirst() {
        val plans = listOf(plan("later", 660, 720), plan("earlier", 540, 660))
        assertEquals(at(monday, 12), project(plans, at(monday, 8), at(monday, 10)))
    }

    /** 一分钟的真实空档必须保留，不能为了合并UI延长锁定展示。 */
    @Test
    fun should_stopAtGap_when_nextPlanStartsOneMinuteLater() {
        assertEquals(at(monday, 10), project(
            listOf(plan("later", 601, 720)), at(monday, 8), at(monday, 10)
        ))
    }

    /** 即使某计划仍在日历上生效，已完成身份也不应继续延长结束投影。 */
    @Test
    fun should_ignoreCompletedOccurrence_when_itWouldBridgeAGap() {
        val plans = listOf(plan("bridge", 540, 660), plan("later", 660, 720))
        val bridge = LockPlanEvaluator.activeWindow(plans, at(monday, 9), zone = zone).requiredValue()
        val projected = LockPlanEvaluator.nextContinuousEnd(
            plans, at(monday, 8), at(monday, 10),
            completedOccurrenceIds = bridge.occurrenceIds, zone = zone
        )
        assertEquals(at(monday, 10), projected)
    }

    /** 当前会话原日历段必须排除，墙钟回拨不能使自身延长展示结束时刻。 */
    @Test
    fun should_excludeCurrentOccurrence_when_projectedCurrentEndMovesWithWallClock() {
        val plans = listOf(plan("current", 480, 600))
        val current = LockPlanEvaluator.activeWindow(plans, at(monday, 8), zone = zone).requiredValue()
        val projected = LockPlanEvaluator.nextContinuousEnd(
            plans, at(monday, 8), at(monday, 9),
            currentOccurrenceIds = current.occurrenceIds, zone = zone
        )
        assertEquals(at(monday, 9), projected)
        assertEquals(at(monday, 10), current.endAt)
    }

    /** 午夜前后的相邻计划应在同一连续投影中，结束仍落在正确日期。 */
    @Test
    fun should_crossMidnight_when_nextDayPlanTouchesCurrentEnd() {
        val nextDay = monday.plusDays(1)
        val plans = listOf(plan("after-midnight", 30, 120, setOf(2)))
        assertEquals(at(nextDay, 2), project(plans, at(monday, 23), at(nextDay, 0, 30)))
    }

    /** 每天全天连续覆盖时不得把有限查询范围的末尾伪装成解除时间。 */
    @Test
    fun should_reportNoFiniteEnd_when_everyDayIsContinuouslyCovered() {
        val plans = listOf(plan("always", 0, 0, (1..7).toSet()))
        assertNull(project(plans, at(monday, 8), at(monday, 10)))
    }

    /** 跨越长时间手动会话后仍须检查当前截止附近的计划，不只看now之后九天。 */
    @Test
    fun should_inspectFarCurrentEnd_when_sessionRunsBeyondDefaultHorizon() {
        val farDay = monday.plusDays(21)
        val plans = listOf(plan("after-long-session", 540, 660))
        assertEquals(at(farDay, 11), project(plans, at(monday, 8), at(farDay, 10)))
    }

    /** 过期当前段不再从它的旧截止点制造新的连续链。 */
    @Test
    fun should_returnExpiredEnd_when_projectionIsCalledAfterCurrentSession() {
        assertEquals(at(monday, 9), project(
            listOf(plan("later", 540, 720)), at(monday, 10), at(monday, 9)
        ))
    }

    /** 即使没有计划，计算展示查询边界也不能在最大epoch附近溢出。 */
    @Test
    fun should_keepCurrentEnd_when_projectionHorizonExceedsLongEpoch() {
        assertEquals(Long.MAX_VALUE, LockPlanEvaluator.nextContinuousEnd(
            emptyList(), Long.MAX_VALUE - 1L, Long.MAX_VALUE, zone = ZoneId.of("UTC")
        ))
    }

    /** 越界候选被跳过后，当前合法截止点仍能作为展示结果。 */
    @Test
    fun should_keepCurrentEnd_when_allExtendingIntervalsExceedLongEpoch() {
        val plans = listOf(plan("daily", 0, 0, (1..7).toSet()))
        assertEquals(Long.MAX_VALUE, LockPlanEvaluator.nextContinuousEnd(
            plans, Long.MAX_VALUE - 1L, Long.MAX_VALUE, zone = ZoneId.of("UTC")
        ))
    }

    private fun project(plans: List<LockPlan>, now: Long, currentEnd: Long): Long? =
        LockPlanEvaluator.nextContinuousEnd(plans, now, currentEnd, zone = zone)

    private fun plan(
        id: String, start: Int, end: Int, days: Set<Int> = setOf(1)
    ): LockPlan = LockPlan(id, id, days = days, ranges = listOf(TimeRange(start, end)))

    private fun at(date: LocalDate, hour: Int, minute: Int = 0): Long =
        date.atTime(hour, minute).atZone(zone).toInstant().toEpochMilli()

    private fun <T : Any> T?.requiredValue(): T {
        assertNotNull("评估结果不应为空", this)
        return this!!
    }
}
