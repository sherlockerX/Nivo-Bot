package io.github.nanomuse.focus.lock

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.LocalDate
import java.time.LocalTime
import java.time.ZoneId

/** 21:00到次日06:00的每日计划：06:00必须解锁，白天不得再次锁定，当晚21:00才开始下一段。 */
class OvernightPlanTest {
    private val zone = ZoneId.of("Asia/Shanghai")
    private val plan = LockPlan("night", "Night", days = (1..7).toSet(), ranges = listOf(TimeRange(21 * 60, 6 * 60)), ownerKey = "me")
    private val day1 = LocalDate.of(2026, 11, 16)

    private fun at(date: LocalDate, hour: Int, minute: Int = 0, second: Int = 0): Long =
        date.atTime(LocalTime.of(hour, minute, second)).atZone(zone).toInstant().toEpochMilli()

    private fun startAt(now: Long, history: List<LockRun> = emptyList()): LockRun {
        val decision = LockScheduleDecision.evaluate(listOf(plan), history, null, now, zone)
        val window = assertNotNull(decision.window).let { decision.window!! }
        val duration = assertNotNull(decision.startDurationMs).let { decision.startDurationMs!! }
        // 与LockStore.start一致：开始墙钟加固定时长，单调钟检查点从0开始。
        return LockRun("me", "run-$now", "s-$now", window.planIds, window.occurrenceIds, now, now + duration, duration,
            window.usesWhitelist, duration, 0, 7)
    }

    @Test fun should_unlockAtSix_when_planStartsAtNine() {
        val run = startAt(at(day1, 21, 0, 0))
        assertEquals(at(day1.plusDays(1), 6), run.deadlineAt)
        // 同一次开机，单调钟从21:00持续走到次日06:00。
        val before = at(day1.plusDays(1), 5, 59)
        assertTrue(run.remaining(before, before - run.startedAt, 7).milliseconds > 0)
        val six = at(day1.plusDays(1), 6)
        assertEquals(0, run.remaining(six, six - run.startedAt, 7).milliseconds)
    }

    @Test fun should_stayUnlockedAllDay_when_nightOccurrenceCompleted() {
        val run = startAt(at(day1, 21, 0, 30)).copy(status = LockRunStatus.COMPLETED)
        for (hour in listOf(6, 7, 9, 12, 15, 20)) {
            val now = at(day1.plusDays(1), hour, 0, 1)
            val decision = LockScheduleDecision.evaluate(listOf(plan), listOf(run), null, now, zone)
            assertNull("re-locked at $hour:00", decision.window)
            assertNull(decision.startDurationMs)
            assertEquals(at(day1.plusDays(1), 21), decision.nextStartAt)
        }
        val tonight = startAt(at(day1.plusDays(1), 21, 0, 5), listOf(run))
        assertEquals(at(day1.plusDays(2), 6), tonight.deadlineAt)
    }

    @Test fun should_unlockAtSix_when_phoneRestartedOvernight() {
        val run = startAt(at(day1, 21))
        // 03:00重启：启动次数变化，按固定截止恢复。
        val three = at(day1.plusDays(1), 3)
        val afterReboot = run.remaining(three, 1_000, 8)
        assertTrue(afterReboot.requiresRebaseline)
        assertEquals(3 * 3_600_000L, afterReboot.milliseconds)
        val six = at(day1.plusDays(1), 6)
        assertEquals(0, run.remaining(six, 5_000, 8).milliseconds)
    }

    @Test fun should_endAtSix_when_planSavedInsideTheNightWindow() {
        // 凌晨01:30才保存计划：只锁到06:00，不能把整段9小时从现在算起。
        val run = startAt(at(day1.plusDays(1), 1, 30))
        assertEquals(at(day1.plusDays(1), 6), run.deadlineAt)
        assertEquals(4 * 3_600_000L + 30 * 60_000L, run.durationMs)
    }
}
