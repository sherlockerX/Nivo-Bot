package io.github.nanomuse.focus.lock

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertThrows
import org.junit.Test
import java.time.LocalDate
import java.time.ZoneId

/** 验证空闲计划检查的时间边界、完成排除与不重复启动规则，不依赖Android调度。 */
class ScheduledStartPolicyTest {
    private val monday = LocalDate.of(2026, 9, 7)
    private val shanghai = ZoneId.of("Asia/Shanghai")
    private val morning = schedule("morning", 480, 540)

    /** 没有任何计划时不保留本地定时任务。 */
    @Test
    fun should_notSchedule_when_noPlansExist() {
        assertEquals(LockStartPolicy.Check(null, false), check(emptyList(), at(8)))
    }

    /** 总开关关闭时，即使当前在活动区间内也不能启动或排本地检查。 */
    @Test
    fun should_notEvaluateOrSchedule_when_masterIsDisabled() {
        assertEquals(LockStartPolicy.Check(null, false),
            check(listOf(morning), at(8), isMasterEnabled = false))
    }

    /** 已有活动会话时不重复评估，由原会话计时路径负责截止。 */
    @Test
    fun should_notEvaluateOrSchedule_when_sessionIsLockedInsideActiveWindow() {
        assertEquals(LockStartPolicy.Check(null, false),
            check(listOf(morning), at(8, 30), isLocked = true))
    }

    /** 已锁机时未来计划也不驱动空闲检查，避免改动原有活动策略调度。 */
    @Test
    fun should_notScheduleFutureCheck_when_sessionIsLocked() {
        assertEquals(LockStartPolicy.Check(null, false),
            check(listOf(morning), at(7), isLocked = true))
    }

    /** 不足一分钟时直接对齐真实开始边界，不额外等待整分钟。 */
    @Test
    fun should_useExactStartBoundary_when_planStartsWithinOneMinute() {
        assertEquals(LockStartPolicy.Check(at(8), false),
            check(listOf(morning), at(7, 59, 45)))
    }

    /** 到点前一毫秒仍不能启动，下一次检查准确指向开始时刻。 */
    @Test
    fun should_waitOneMillisecond_when_startBoundaryHasNotArrived() {
        assertEquals(LockStartPolicy.Check(at(8), false),
            check(listOf(morning), at(8) - 1L))
    }

    /** 远期计划最多一分钟重新计算，期间不请求完整控制器评估。 */
    @Test
    fun should_recheckWithinOneMinute_when_planIsMoreThanThirtyMinutesAway() {
        val now = at(6)
        assertEquals(LockStartPolicy.Check(now + 60_000L, false),
            check(listOf(morning), now))
    }

    /** 多条计划输入无序时，仍使用最近一个真实开始边界。 */
    @Test
    fun should_chooseNearestBoundary_when_plansAreUnsorted() {
        val plans = listOf(schedule("later", 600, 660), morning)
        assertEquals(LockStartPolicy.Check(at(8), false),
            check(plans, at(7, 59, 45)))
    }

    /** 开始边界属于活动区间，立即评估；尚未成功启动则三十秒后复查。 */
    @Test
    fun should_evaluateImmediately_when_startBoundaryArrives() {
        assertEquals(LockStartPolicy.Check(at(8) + 30_000L, true),
            check(listOf(morning), at(8)))
    }

    /** 迟到但仍处于有效区间时允许补启动，重试间隔保持三十秒。 */
    @Test
    fun should_retryInThirtySeconds_when_currentWindowIsStillActive() {
        val now = at(8, 17, 12)
        assertEquals(LockStartPolicy.Check(now + 30_000L, true),
            check(listOf(morning), now))
    }

    /** 活动区间末尾仍可评估，但迟到至右端点后不能补锁已经结束的时段。 */
    @Test
    fun should_stopEvaluatingAtExactEnd_when_activeWindowExpires() {
        val endAt = at(9)
        assertEquals(LockStartPolicy.Check(endAt, true),
            check(listOf(morning), endAt - 1L))
        assertEquals(LockStartPolicy.Check(endAt + 60_000L, false),
            check(listOf(morning), endAt))
    }

    /** 不足三十秒时重试对齐结束点，不能越过当前窗口。 */
    @Test
    fun should_capRetryAtEnd_when_lessThanThirtySecondsRemain() {
        assertEquals(LockStartPolicy.Check(at(9), true),
            check(listOf(morning), at(8, 59, 40)))
    }

    /** 剩余恰好三十秒时仍只安排结束边界一次复查。 */
    @Test
    fun should_useExactEnd_when_thirtySecondsRemain() {
        assertEquals(LockStartPolicy.Check(at(9), true),
            check(listOf(morning), at(8, 59, 30)))
    }

    /** 重叠合并后的最晚结束点决定下一次重试上限。 */
    @Test
    fun should_useMergedEnd_when_shortWindowOverlapsLongerWindow() {
        val plans = listOf(morning, schedule("longer", 530, 541))
        assertEquals(LockStartPolicy.Check(at(9, 0, 10), true), check(plans, at(8, 59, 40)))
    }

    /** 睡眠错过整段后只等待未来周次，不根据上一段时长补锁。 */
    @Test
    fun should_onlyScheduleFutureCheck_when_entireWindowWasMissed() {
        val now = at(12)
        assertEquals(LockStartPolicy.Check(now + 60_000L, false),
            check(listOf(morning), now))
    }

    /** 稳定身份排除规则与控制器一致，时区变化不重放同一日历任务。 */
    @Test
    fun should_skipCompletedOccurrence_when_timezoneChanges() {
        val completed = LockPlanEvaluator.activeWindow(
            listOf(morning), at(8), zone = shanghai
        ).requiredValue().occurrenceIds
        val now = at(9)
        assertEquals(LockStartPolicy.Check(now + 60_000L, false),
            check(listOf(morning), now, completedOccurrenceIds = completed,
                zone = ZoneId.of("Asia/Bangkok")))
    }

    /** 墙钟回拨令已完成任务重新出现在未来时，检查不能对齐该已完成边界。 */
    @Test
    fun should_skipCompletedFutureBoundary_when_clockMovesBackwards() {
        val completed = LockPlanEvaluator.activeWindow(
            listOf(morning), at(8), zone = shanghai
        ).requiredValue().occurrenceIds
        val now = at(7, 59, 45)
        assertEquals(LockStartPolicy.Check(now + 60_000L, false),
            check(listOf(morning), now, completedOccurrenceIds = completed))
    }

    /** 完成集合遮住整个有限搜索范围时，也必须等待范围外下一周次。 */
    @Test
    fun should_keepPeriodicCheck_when_onlyFutureWindowInsideHorizonWasCompleted() {
        val completed = LockPlanEvaluator.activeWindow(
            listOf(morning), at(8, date = monday.plusWeeks(1)), zone = shanghai
        ).requiredValue().occurrenceIds
        val now = at(7, date = monday.plusDays(1))
        assertEquals(LockStartPolicy.Check(now + 60_000L, false),
            check(listOf(morning), now, completedOccurrenceIds = completed))
    }

    /** 完成记录覆盖多周后回拨，有限搜索结果为空不能取消重复计划。 */
    @Test
    fun should_keepPeriodicCheck_when_multipleCompletedOccurrencesHideFutureCandidates() {
        val completed = (0L..3L).flatMap { week ->
            LockPlanEvaluator.activeWindow(
                listOf(morning), at(8, date = monday.plusWeeks(week)), zone = shanghai
            ).requiredValue().occurrenceIds
        }.toSet()
        val now = at(7)
        assertEquals(LockStartPolicy.Check(now + 60_000L, false),
            check(listOf(morning), now, completedOccurrenceIds = completed))
    }

    /** 时间上界不能因为日历投影溢出而使启动检查异常退出。 */
    @Test
    fun should_saturatePeriodicCheck_when_nowIsMaximumEpoch() {
        val daily = morning.copy(days = (1..7).toSet())
        assertEquals(LockStartPolicy.Check(Long.MAX_VALUE, false),
            check(listOf(daily), Long.MAX_VALUE, zone = ZoneId.of("UTC")))
    }

    /** 时间下界跳过越界区间后，仍正常安排下一次有界复查。 */
    @Test
    fun should_keepPeriodicCheck_when_nowIsMinimumEpoch() {
        val daily = morning.copy(days = (1..7).toSet())
        assertEquals(LockStartPolicy.Check(Long.MIN_VALUE + 60_000L, false),
            check(listOf(daily), Long.MIN_VALUE, zone = ZoneId.of("UTC")))
    }

    /** 完成某条计划不应屏蔽具有相同开始时间的其他计划。 */
    @Test
    fun should_evaluateDifferentPlan_when_onlyOneOccurrenceWasCompleted() {
        val completed = LockPlanEvaluator.activeWindow(
            listOf(morning), at(8), zone = shanghai
        ).requiredValue().occurrenceIds
        val now = at(8, 30)
        assertEquals(LockStartPolicy.Check(now + 30_000L, true),
            check(listOf(morning, schedule("different", 480, 600)), now,
                completedOccurrenceIds = completed))
    }

    /** 跨午夜计划在次日仍是活动区间，结束点之后不再补启动。 */
    @Test
    fun should_evaluateAfterMidnightOnlyBeforeEnd_when_planStartedYesterday() {
        val plans = listOf(schedule("overnight", 23 * 60, 30))
        val nextDay = monday.plusDays(1)
        val now = at(0, 15, date = nextDay)
        val endAt = at(0, 30, date = nextDay)
        assertEquals(LockStartPolicy.Check(now + 30_000L, true), check(plans, now))
        assertEquals(LockStartPolicy.Check(endAt + 60_000L, false), check(plans, endAt))
    }

    /** 午夜前的未来任务使用次日真正的开始边界。 */
    @Test
    fun should_scheduleNextMidnightBoundary_when_planBelongsToNextDay() {
        val plans = listOf(schedule("midnight", 0, 60).copy(days = setOf(2)))
        assertEquals(LockStartPolicy.Check(at(0, date = monday.plusDays(1)), false),
            check(plans, at(23, 59, 45)))
    }

    /** 空时段、空星期及停用计划均不能形成可执行检查。 */
    @Test
    fun should_notSchedule_when_allPlansAreDisabledOrInvalid() {
        val plans = listOf(
            morning.copy(id = "disabled", isEnabled = false),
            morning.copy(id = "no-days", days = emptySet()),
            morning.copy(id = "no-ranges", ranges = emptyList())
        )
        assertEquals(LockStartPolicy.Check(null, false), check(plans, at(8)))
    }

    /** 起止分钟相同是模型定义的全天计划，不能误判为空时段。 */
    @Test
    fun should_evaluateWholeDay_when_startAndEndMinutesMatch() {
        val now = at(12)
        assertEquals(LockStartPolicy.Check(now + 30_000L, true),
            check(listOf(schedule("whole-day", 0, 0)), now))
    }

    /** 夏令时缺失小时使某段无正时长时，不应生成一个补锁请求。 */
    @Test
    fun should_skipCollapsedDstWindow_when_localEndIsNotAfterResolvedStart() {
        val zone = ZoneId.of("America/New_York")
        val date = LocalDate.of(2026, 3, 8)
        val now = at(3, 15, date = date, zone = zone)
        val plans = listOf(schedule("dst-gap", 150, 180).copy(days = setOf(7)))
        assertEquals(LockStartPolicy.Check(now + 60_000L, false),
            check(plans, now, zone = zone))
    }

    /** 每次计算只使用当前时间，前跳到活动期与越过末尾分别重算。 */
    @Test
    fun should_recomputeFromCurrentWallTime_when_clockJumpsForward() {
        val plans = listOf(morning)
        assertEquals(LockStartPolicy.Check(at(7) + 60_000L, false), check(plans, at(7)))
        assertEquals(LockStartPolicy.Check(at(8, 30) + 30_000L, true),
            check(plans, at(8, 30)))
        assertEquals(LockStartPolicy.Check(at(10) + 60_000L, false), check(plans, at(10)))
    }

    /** 开始策略不能把不同账户的计划合并为一个检查请求。 */
    @Test
    fun should_rejectMixedOwners_when_plansBelongToDifferentAccounts() {
        val plans = listOf(morning.copy(ownerKey = "account-one"),
            schedule("other", 480, 600).copy(ownerKey = "account-two"))
        assertThrows(IllegalArgumentException::class.java) { check(plans, at(8)) }
    }

    private fun check(
        schedules: List<LockPlan>,
        now: Long,
        isMasterEnabled: Boolean = true,
        isLocked: Boolean = false,
        completedOccurrenceIds: Set<String> = emptySet(),
        zone: ZoneId = shanghai
    ): LockStartPolicy.Check = LockStartPolicy.nextCheck(
        schedules, isMasterEnabled, isLocked, now, completedOccurrenceIds, zone
    )

    private fun schedule(id: String, startMinute: Int, endMinute: Int): LockPlan = LockPlan(
        id = id, name = id, days = setOf(1), ranges = listOf(TimeRange(startMinute, endMinute))
    )

    private fun at(
        hour: Int,
        minute: Int = 0,
        second: Int = 0,
        date: LocalDate = monday,
        zone: ZoneId = shanghai
    ): Long = date.atTime(hour, minute, second).atZone(zone).toInstant().toEpochMilli()

    private fun <T : Any> T?.requiredValue(): T {
        assertNotNull("评估结果不应为空", this)
        return this!!
    }
}
