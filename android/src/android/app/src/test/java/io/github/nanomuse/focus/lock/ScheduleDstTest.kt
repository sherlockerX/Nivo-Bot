package io.github.nanomuse.focus.lock

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.LocalDate
import java.time.ZoneId
import java.util.TimeZone

/** 验证本地日程在夏令时和不同宿主时区下保持用户设置的时刻。 */
class ScheduleDstTest {
    /** 春季时区偏移变化后仍按当地八点开始。 */
    @Test
    fun should_startAtEight_when_springOffsetChanges() {
        assertDaytimeRange(LocalDate.of(2026, 3, 8))
    }

    /** 秋季时区偏移变化后仍按当地八点开始。 */
    @Test
    fun should_startAtEight_when_autumnOffsetChanges() {
        assertDaytimeRange(LocalDate.of(2026, 11, 1))
    }

    /** 跨越春季跳时的夜间计划仍按当地六点结束。 */
    @Test
    fun should_endAtSix_when_overnightRangeCrossesSpringOffsetChange() {
        val zone = ZoneId.of("America/New_York")
        val date = LocalDate.of(2026, 3, 7)
        val schedule = LockPlan("overnight", "跨天", days = setOf(6),
            ranges = listOf(TimeRange(22 * 60 + 30, 6 * 60)))
        val interval = LockPlanEvaluator.intervals(
            listOf(schedule), at(date, 23, zone), 0, 0, zone
        ).also { assertEquals(1, it.size) }.single()
        assertEquals(at(date.plusDays(1), 6, zone), interval.end)
        assertEquals(390 * 60_000L, interval.end - interval.start)
    }

    /** 显式时区优先于测试机器的默认时区。 */
    @Test
    fun should_useRequestedZone_when_systemZoneDiffers() {
        val originalZone = TimeZone.getDefault()
        try {
            TimeZone.setDefault(TimeZone.getTimeZone("UTC"))
            val zone = ZoneId.of("Asia/Shanghai")
            val date = LocalDate.of(2026, 9, 7)
            val schedule = LockPlan("today", "今日", days = (1..7).toSet(),
                ranges = listOf(TimeRange(480, 540), TimeRange(1320, 1380)))
            val intervals = LockPlanEvaluator.todayIntervals(
                listOf(schedule), at(date, 12, zone), zone
            )
            assertEquals(listOf(at(date, 8, zone), at(date, 22, zone)),
                intervals.map { it.start })
        } finally {
            TimeZone.setDefault(originalZone)
        }
    }

    /** 被国际日期变更整日跳过的周五，不能在周六补锁。 */
    @Test
    fun should_skipMissingCalendarDate_when_dateLineMovesForwardByOneDay() {
        val zone = ZoneId.of("Pacific/Apia")
        val saturday = LocalDate.of(2011, 12, 31)
        val schedule = LockPlan("friday", "周五", days = setOf(5),
            ranges = listOf(TimeRange(480, 540)))
        val now = saturday.atTime(8, 30).atZone(zone).toInstant().toEpochMilli()
        assertNull(LockPlanEvaluator.activeWindow(listOf(schedule), now, zone = zone))
        assertTrue(LockPlanEvaluator.todayIntervals(listOf(schedule), now, zone).isEmpty())
        val intervals = LockPlanEvaluator.intervals(listOf(schedule), now, zone = zone)
        assertTrue(intervals.none { it.occurrenceId.contains(":2011-12-30:") })
    }

    /** 跳过日期与真实次日不能生成两个映射到同一时段的身份。 */
    @Test
    fun should_keepOnlyActualDateIdentity_when_skippedAndActualWeekdaysAreSelected() {
        val zone = ZoneId.of("Pacific/Apia")
        val saturday = LocalDate.of(2011, 12, 31)
        val schedule = LockPlan("daily", "每日", days = (1..7).toSet(),
            ranges = listOf(TimeRange(480, 540)))
        val now = saturday.atTime(8, 30).atZone(zone).toInstant().toEpochMilli()
        val intervals = LockPlanEvaluator.todayIntervals(listOf(schedule), now, zone)
        assertEquals(1, intervals.size)
        assertEquals("occ:v1:5:daily:2011-12-31:480:540", intervals.single().occurrenceId)
    }

    /** 普通DST缺失小时仍按原契约顺延，不能被整日缺失修复误删。 */
    @Test
    fun should_shiftMissingHourWithinSameDate_when_dstGapKeepsPositiveDuration() {
        val zone = ZoneId.of("America/New_York")
        val date = LocalDate.of(2026, 3, 8)
        val schedule = LockPlan("spring", "春季", days = setOf(7),
            ranges = listOf(TimeRange(150, 240)))
        val intervals = LockPlanEvaluator.intervals(listOf(schedule), at(date, 3, zone), 0, 0, zone)
        assertEquals(1, intervals.size)
        val interval = intervals.single()
        assertEquals(date.atTime(3, 30).atZone(zone).toInstant().toEpochMilli(), interval.start)
        assertEquals(at(date, 4, zone), interval.end)
        assertEquals(30L * 60_000L, interval.end - interval.start)
        assertEquals("occ:v1:6:spring:2026-03-08:150:240", interval.occurrenceId)
    }

    /** 秋季完整日历日可以有25小时，求值器不负责截断单次会话上限。 */
    @Test
    fun should_keepFullCalendarDay_when_autumnOffsetAddsOneHour() {
        val zone = ZoneId.of("America/New_York")
        val date = LocalDate.of(2026, 11, 1)
        val schedule = LockPlan("autumn", "秋季", days = setOf(7),
            ranges = listOf(TimeRange(0, 0)))
        val intervals = LockPlanEvaluator.intervals(listOf(schedule), at(date, 12, zone), 0, 0, zone)
        assertEquals(1, intervals.size)
        assertEquals(25L * 60L * 60_000L, intervals.single().end - intervals.single().start)
    }

    private fun assertDaytimeRange(date: LocalDate) {
        val zone = ZoneId.of("America/New_York")
        val schedule = LockPlan("dst", "八点", days = setOf(7),
            ranges = listOf(TimeRange(480, 540)))
        val interval = LockPlanEvaluator.intervals(
            listOf(schedule), at(date, 12, zone), 0, 0, zone
        ).also { assertEquals(1, it.size) }.single()
        assertEquals(at(date, 8, zone), interval.start)
        assertEquals(at(date, 9, zone), interval.end)
    }

    private fun at(date: LocalDate, hour: Int, zone: ZoneId): Long =
        date.atTime(hour, 0).atZone(zone).toInstant().toEpochMilli()
}
