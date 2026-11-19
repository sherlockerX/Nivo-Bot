package io.github.nanomuse.focus.lock

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.DayOfWeek
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId

/** 验证计划模型、区间展开、合并窗口及损坏参数的公开契约。 */
class ScheduleEvaluatorTest {
    private val zone = ZoneId.of("Asia/Shanghai")
    private val monday = LocalDate.of(2026, 9, 7)

    /** 普通日内区间使用两端分钟差。 */
    @Test
    fun should_countCalendarMinutes_when_rangeIsWithinDay() {
        val range = TimeRange(480, 720)
        assertEquals(240, range.durationMinutes)
        assertFalse(range.isCrossingMidnight)
        assertFalse(range.isWholeDay)
    }

    /** 跨午夜区间的结束分钟属于次日。 */
    @Test
    fun should_countAcrossMidnight_when_endPrecedesStart() {
        val range = TimeRange(1350, 360)
        assertEquals(450, range.durationMinutes)
        assertTrue(range.isCrossingMidnight)
    }

    /** 相同起止分钟是整日，不是零时长。 */
    @Test
    fun should_countWholeDay_when_endEqualsStart() {
        for (minute in listOf(0, 480, 1439)) {
            val range = TimeRange(minute, minute)
            assertEquals(1440, range.durationMinutes)
            assertTrue(range.isWholeDay)
            assertTrue(range.isCrossingMidnight)
        }
    }

    /** 损坏分钟必须报错，不能夹取成意外的全天计划。 */
    @Test
    fun should_rejectMinutes_when_rangeIsOutsideCalendarDay() {
        for ((startMinute, endMinute) in listOf(-1 to 480, 480 to -1, 1440 to 0,
            0 to 1440, Int.MIN_VALUE to Int.MAX_VALUE)) {
            assertThrows(IllegalArgumentException::class.java) {
                TimeRange(startMinute, endMinute)
            }
        }
    }

    /** 空计划身份不能被用作稳定时段身份。 */
    @Test
    fun should_rejectPlan_when_idIsBlank() {
        assertThrows(IllegalArgumentException::class.java) { plan(id = " ") }
    }

    /** 非法星期不能悄悄作为一个被忽略的有效计划保存。 */
    @Test
    fun should_rejectPlan_when_weekdaysAreOutsideOneToSeven() {
        for (days in listOf(setOf(0), setOf(8), setOf(1, -1))) {
            assertThrows(IllegalArgumentException::class.java) { plan(days = days) }
        }
    }

    /** 非正修订号属于损坏的计划输入。 */
    @Test
    fun should_rejectPlan_when_revisionIsNotPositive() {
        assertThrows(IllegalArgumentException::class.java) { plan().copy(revision = 0L) }
        assertThrows(IllegalArgumentException::class.java) { plan().copy(revision = -1L) }
    }

    /** 纯模型允许尚未由存储层绑定账户的默认构造。 */
    @Test
    fun should_keepOptionalDefaults_when_planIsPreparedBeforePersistence() {
        val draft = LockPlan("draft", "草稿")
        assertEquals("", draft.ownerKey)
        assertEquals(1L, draft.revision)
        assertNull(draft.title)
        assertNull(draft.taskId)
        assertTrue(draft.isEnabled)
        assertTrue(draft.usesWhitelist)
    }

    /** 只在指定星期按当地时刻展开。 */
    @Test
    fun should_expandMondayAtEight_when_onlyMondayIsSelected() {
        val intervals = LockPlanEvaluator.intervals(listOf(plan()), at(monday, 10), zone = zone)
        assertTrue("应展开至少一个周一区间", intervals.isNotEmpty())
        intervals.forEach { interval ->
            val start = Instant.ofEpochMilli(interval.start).atZone(zone)
            assertEquals(DayOfWeek.MONDAY, start.dayOfWeek)
            assertEquals(8, start.hour)
            assertEquals(0, start.minute)
            assertEquals(14_400_000L, interval.end - interval.start)
        }
        assertTrue(intervals.any { it.start == at(monday, 8) })
    }

    /** 跨午夜段必须把结束日期推进一天。 */
    @Test
    fun should_endNextMorning_when_rangeCrossesMidnight() {
        val intervals = LockPlanEvaluator.intervals(
            listOf(plan(ranges = listOf(TimeRange(1350, 360)))), at(monday, 23),
            backDays = 0, forwardDays = 0, zone = zone
        )
        assertEquals(1, intervals.size)
        assertEquals(at(monday, 22, 30), intervals.single().start)
        assertEquals(at(monday.plusDays(1), 6), intervals.single().end)
    }

    /** 停用计划没有日历区间。 */
    @Test
    fun should_returnNoIntervals_when_planIsDisabled() {
        assertTrue(LockPlanEvaluator.intervals(
            listOf(plan(isEnabled = false)), at(monday, 10), zone = zone
        ).isEmpty())
    }

    /** 一周七天均被选中时每天都生成一个区间。 */
    @Test
    fun should_expandSevenIntervals_when_everyWeekdayIsSelected() {
        assertEquals(7, LockPlanEvaluator.intervals(
            listOf(plan(days = (1..7).toSet())), at(monday, 10),
            backDays = 0, forwardDays = 6, zone = zone
        ).size)
    }

    /** 负投影范围必须拒绝，避免静默得到空结果。 */
    @Test
    fun should_rejectProjection_when_dayCountsAreNegative() {
        assertThrows(IllegalArgumentException::class.java) {
            LockPlanEvaluator.intervals(listOf(plan()), at(monday, 8), backDays = -1, zone = zone)
        }
        assertThrows(IllegalArgumentException::class.java) {
            LockPlanEvaluator.intervals(listOf(plan()), at(monday, 8), forwardDays = -1, zone = zone)
        }
    }

    /** 任一侧超过366天都必须在展开前拒绝。 */
    @Test
    fun should_rejectProjection_when_eitherSideExceedsMaximumDays() {
        val plans = listOf(plan(days = (1..7).toSet()))
        for ((backDays, forwardDays) in listOf(367L to 0L, 0L to 367L)) {
            assertThrows(IllegalArgumentException::class.java) {
                LockPlanEvaluator.intervals(plans, at(monday, 8), backDays, forwardDays, zone)
            }
        }
    }

    /** 两侧各自合法但总跨度超过366天时同样拒绝。 */
    @Test
    fun should_rejectProjection_when_combinedSpanExceedsMaximumDays() {
        assertThrows(IllegalArgumentException::class.java) {
            LockPlanEvaluator.intervals(listOf(plan()), at(monday, 8), 183L, 184L, zone)
        }
    }

    /** 极大输入使用空计划验证前置校验，避免RED阶段实际执行无界展开。 */
    @Test
    fun should_rejectProjectionWithoutOverflow_when_dayCountsApproachLongMaximum() {
        for ((backDays, forwardDays) in listOf(
            Long.MAX_VALUE to 0L, 0L to Long.MAX_VALUE, Long.MAX_VALUE to Long.MAX_VALUE
        )) {
            assertThrows(IllegalArgumentException::class.java) {
                LockPlanEvaluator.intervals(emptyList(), at(monday, 8), backDays, forwardDays, zone)
            }
        }
    }

    /** 停用状态不能跳过公开参数的范围校验。 */
    @Test
    fun should_rejectProjection_when_disabledPlanReceivesExcessiveSpan() {
        assertThrows(IllegalArgumentException::class.java) {
            LockPlanEvaluator.intervals(listOf(plan(isEnabled = false)), at(monday, 8), 366L, 1L, zone)
        }
    }

    /** 总跨度恰好366天合法，包含中心日后应展开367个日期。 */
    @Test
    fun should_keepBoundaryProjection_when_combinedSpanIsExactlyMaximumDays() {
        val plans = listOf(plan(days = (1..7).toSet()))
        for ((backDays, forwardDays) in listOf(0L to 366L, 366L to 0L, 183L to 183L)) {
            val intervals = LockPlanEvaluator.intervals(
                plans, at(monday, 8), backDays, forwardDays, zone
            )
            assertEquals(367, intervals.size)
            assertEquals(at(monday.minusDays(backDays), 8), intervals.first().start)
            assertEquals(at(monday.plusDays(forwardDays), 12), intervals.last().end)
        }
    }

    /** Long两端仅跳过无法表示的区间，仍保留附近完整合法区间。 */
    @Test
    fun should_keepRepresentableIntervals_when_epochTouchesLongBoundaries() {
        val utc = ZoneId.of("UTC")
        val plans = listOf(plan(days = (1..7).toSet(), ranges = listOf(TimeRange(480, 540))))
        for ((around, safeOffset) in listOf(Long.MIN_VALUE to 1L, Long.MAX_VALUE to -1L)) {
            val safeDate = Instant.ofEpochMilli(around).atZone(utc).toLocalDate().plusDays(safeOffset)
            val safeStart = safeDate.atTime(8, 0).atZone(utc).toInstant().toEpochMilli()
            val intervals = LockPlanEvaluator.intervals(plans, around, zone = utc)
            assertTrue("邻近日历范围内的合法时段不能一起丢弃", intervals.any { it.start == safeStart })
            assertTrue(intervals.all { it.start < it.end })
        }
    }

    /** 不完整且超出Long毫秒范围的时段不会被截断成活动窗口。 */
    @Test
    fun should_returnNoActiveWindow_when_epochBoundaryCannotContainCompleteRange() {
        val utc = ZoneId.of("UTC")
        val plans = listOf(plan(days = (1..7).toSet(), ranges = listOf(TimeRange(0, 0))))
        assertNull(LockPlanEvaluator.activeWindow(plans, Long.MIN_VALUE, zone = utc))
        assertNull(LockPlanEvaluator.activeWindow(plans, Long.MAX_VALUE, zone = utc))
    }

    /** 最小epoch之后仍能找到下一日时段，最大epoch之后没有可表示的未来开始。 */
    @Test
    fun should_findOnlyRepresentableFuture_when_epochTouchesLongBoundaries() {
        val utc = ZoneId.of("UTC")
        val plans = listOf(plan(days = (1..7).toSet(), ranges = listOf(TimeRange(480, 540))))
        val nextDate = Instant.ofEpochMilli(Long.MIN_VALUE).atZone(utc).toLocalDate().plusDays(1L)
        val expectedStart = nextDate.atTime(8, 0).atZone(utc).toInstant().toEpochMilli()
        val next = LockPlanEvaluator.nextWindow(plans, Long.MIN_VALUE, utc)
        assertNotNull(next)
        assertEquals(expectedStart, next!!.start)
        assertNull(LockPlanEvaluator.nextWindow(plans, Long.MAX_VALUE, utc))
    }

    /** 当天边界本身超出Long毫秒范围时，空时间轴也不能抛出算术异常。 */
    @Test
    fun should_returnEmptyToday_when_dayBoundaryExceedsLongEpoch() {
        val utc = ZoneId.of("UTC")
        val plans = listOf(plan(days = (1..7).toSet(), ranges = listOf(TimeRange(0, 0))))
        for (now in listOf(Long.MIN_VALUE, Long.MAX_VALUE)) {
            assertTrue(LockPlanEvaluator.todayIntervals(emptyList(), now, utc).isEmpty())
            assertTrue(LockPlanEvaluator.todayIntervals(plans, now, utc).isEmpty())
        }
    }

    /** 活动窗口保留计划、账户及全部具体时段身份。 */
    @Test
    fun should_returnAccountWindow_when_nowFallsInsideInterval() {
        val window = active(listOf(plan()), at(monday, 10))
        assertEquals(at(monday, 8), window.startAt)
        assertEquals(at(monday, 12), window.endAt)
        assertEquals(setOf("first"), window.planIds)
        assertEquals(setOf("first"), window.planNames)
        assertEquals("account-one", window.ownerKey)
        assertEquals(setOf("occ:v1:5:first:2026-09-07:480:720"), window.occurrenceIds)
    }

    /** 区间外不得发布活动窗口。 */
    @Test
    fun should_returnNoWindow_when_nowIsOutsideInterval() {
        assertNull(LockPlanEvaluator.activeWindow(listOf(plan()), at(monday, 7), zone = zone))
        assertNull(LockPlanEvaluator.activeWindow(listOf(plan()), at(monday, 13), zone = zone))
    }

    /** 跨午夜后仍属于前一天开始的计划。 */
    @Test
    fun should_keepOriginalStartDate_when_nowIsAfterMidnight() {
        val window = active(listOf(plan(ranges = listOf(TimeRange(1350, 360)))),
            at(monday.plusDays(1), 2))
        assertEquals(at(monday, 22, 30), window.startAt)
        assertEquals(at(monday.plusDays(1), 6), window.endAt)
    }

    /** 重叠合并必须保留全部来源，不能只留下第一条计划ID。 */
    @Test
    fun should_mergeAllPlanIdentities_when_intervalsOverlap() {
        val window = active(listOf(
            plan("first", ranges = listOf(TimeRange(480, 600))),
            plan("second", ranges = listOf(TimeRange(540, 720)))
        ), at(monday, 9, 30))
        assertEquals(at(monday, 8), window.startAt)
        assertEquals(at(monday, 12), window.endAt)
        assertEquals(setOf("first", "second"), window.planIds)
        assertEquals(setOf("first", "second"), window.planNames)
        assertEquals(setOf("occ:v1:5:first:2026-09-07:480:600",
            "occ:v1:6:second:2026-09-07:540:720"), window.occurrenceIds)
    }

    /** 任一当前活动计划关闭白名单，合并窗口就必须收紧。 */
    @Test
    fun should_disableWhitelist_when_anyActivePlanDisallowsIt() {
        val window = active(listOf(plan("allowed"), plan("blocked",
            ranges = listOf(TimeRange(540, 600)), usesWhitelist = false)), at(monday, 9, 30))
        assertFalse(window.usesWhitelist)
        assertTrue(active(listOf(plan("allowed")), at(monday, 9, 30)).usesWhitelist)
    }

    /** 完成集合使用稳定时段身份，回拨时不得重新启动。 */
    @Test
    fun should_excludeCompletedOccurrence_when_wallClockReturnsInsideIt() {
        val plans = listOf(plan())
        val completed = active(plans, at(monday, 10)).occurrenceIds
        assertNull(LockPlanEvaluator.activeWindow(plans, at(monday, 10), completed, zone))
    }

    /** 下一窗口必须严格晚于当前时刻。 */
    @Test
    fun should_findNextStart_when_planIsStillInFuture() {
        val interval = LockPlanEvaluator.nextWindow(listOf(plan()), at(monday, 0, 30), zone)
        assertNotNull(interval)
        assertEquals(at(monday, 8), interval!!.start)
    }

    /** 正在进行的本周时段不再作为下一个开始点。 */
    @Test
    fun should_findFollowingWeek_when_currentOccurrenceHasStarted() {
        val interval = LockPlanEvaluator.nextWindow(listOf(plan()), at(monday, 10), zone)
        assertNotNull(interval)
        assertEquals(at(monday.plusWeeks(1), 8), interval!!.start)
    }

    /** 停用后不存在未来窗口。 */
    @Test
    fun should_returnNoNextWindow_when_planIsDisabled() {
        assertNull(LockPlanEvaluator.nextWindow(listOf(plan(isEnabled = false)), at(monday, 8), zone))
    }

    /** 当天时间轴只返回与显式本地日相交的区间。 */
    @Test
    fun should_returnTodayIntervals_when_otherDatesAreProjected() {
        val intervals = LockPlanEvaluator.todayIntervals(listOf(
            plan("morning", (1..7).toSet(), listOf(TimeRange(480, 540))),
            plan("night", (1..7).toSet(), listOf(TimeRange(1320, 1380)))
        ), at(monday, 12), zone)
        assertEquals(2, intervals.size)
        assertEquals(listOf(at(monday, 8), at(monday, 22)), intervals.map { it.start })
    }

    /** 周合计保留配置分钟总量的原始语义。 */
    @Test
    fun should_countWeeklyMinutes_when_multipleDaysAndRangesExist() {
        assertEquals(630, plan(days = setOf(1, 3, 5),
            ranges = listOf(TimeRange(480, 600), TimeRange(840, 930))).weeklyMinutes)
    }

    /** 所有查询入口拒绝跨账号计划，不能合并或部分过滤后继续评估。 */
    @Test
    fun should_rejectMixedOwners_when_anyEvaluatorEntryReceivesThem() {
        val plans = listOf(plan(), plan("other").copy(ownerKey = "account-two"))
        val now = at(monday, 9)
        assertThrows(IllegalArgumentException::class.java) {
            LockPlanEvaluator.intervals(plans, now, zone = zone)
        }
        assertThrows(IllegalArgumentException::class.java) {
            LockPlanEvaluator.activeWindow(plans, now, zone = zone)
        }
        assertThrows(IllegalArgumentException::class.java) {
            LockPlanEvaluator.nextWindow(plans, now, zone = zone)
        }
        assertThrows(IllegalArgumentException::class.java) {
            LockPlanEvaluator.todayIntervals(plans, now, zone = zone)
        }
        assertThrows(IllegalArgumentException::class.java) {
            LockPlanEvaluator.nextContinuousEnd(plans, now, at(monday, 10), zone = zone)
        }
    }

    /** 停用状态不能使混入的其他账号计划绕过输入隔离校验。 */
    @Test
    fun should_rejectMixedOwners_when_otherAccountPlanIsDisabled() {
        assertThrows(IllegalArgumentException::class.java) {
            LockPlanEvaluator.intervals(listOf(plan(),
                plan("other", isEnabled = false).copy(ownerKey = "account-two")),
                at(monday, 9), zone = zone)
        }
    }

    private fun active(plans: List<LockPlan>, now: Long): LockWindow {
        val window = LockPlanEvaluator.activeWindow(plans, now, zone = zone)
        assertNotNull("此刻应存在活动窗口", window)
        return window!!
    }

    private fun plan(
        id: String = "first",
        days: Set<Int> = setOf(1),
        ranges: List<TimeRange> = listOf(TimeRange(480, 720)),
        isEnabled: Boolean = true,
        usesWhitelist: Boolean = true
    ) = LockPlan(id, id, days, ranges, isEnabled, usesWhitelist, ownerKey = "account-one")

    private fun at(date: LocalDate, hour: Int, minute: Int = 0): Long =
        date.atTime(hour, minute).atZone(zone).toInstant().toEpochMilli()
}
