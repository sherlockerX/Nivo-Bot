package io.github.nanomuse.focus.lock

import org.junit.Assert.*
import org.junit.Test
import java.time.Instant
import java.time.ZoneId

/** 验证调度身份、重叠和24小时截断，不以Android闹钟代替日历决策。 */
class LockScheduleDecisionTest {
    private val zone = ZoneId.of("UTC")
    private val now = Instant.parse("2026-11-17T10:00:00Z").toEpochMilli()
    private fun plan(id: String, start: Int, end: Int, whitelist: Boolean = true) =
        LockPlan(id, id, setOf(2), listOf(TimeRange(start, end)), usesWhitelist=whitelist)

    @Test fun should_mergeActivePlans_when_theyOverlap() {
        val decision = LockScheduleDecision.evaluate(listOf(plan("a",590,610), plan("b",595,620,false)),emptyList(),null,now,zone)
        assertEquals(1_200_000L, decision.startDurationMs)
        assertFalse(decision.window!!.usesWhitelist)
        assertEquals(setOf("a","b"), decision.window.planIds)
    }
    @Test fun should_excludeCompletedOccurrence_when_wallClockReplays() {
        val plans=listOf(plan("a",590,610))
        val first=LockScheduleDecision.evaluate(plans,emptyList(),null,now,zone)
        val done=LockRun("","r","s",setOf("a"),first.window!!.occurrenceIds,now,now+600000,600000,true,0,10,1,LockRunStatus.COMPLETED,now+600000)
        assertNull(LockScheduleDecision.evaluate(plans,listOf(done),null,now,zone).window)
    }
    @Test fun should_tightenWithoutReplacingDeadline_when_newOverlapStarts() {
        val run=LockRun("","r","s",emptySet(),emptySet(),now,now+600000,600000,true,600000,10,1)
        val decision=LockScheduleDecision.evaluate(listOf(plan("a",600,620,false)),listOf(run),run,now,zone)
        assertNull(decision.startDurationMs)
        assertFalse(decision.usesWhitelist)
        assertEquals(setOf("a"), decision.activePlanIds)
    }
    @Test fun should_capDstDayAndRetainIdentity_when_windowExceeds24Hours() {
        val local=ZoneId.of("America/New_York")
        val start=Instant.parse("2026-11-01T04:00:00Z").toEpochMilli()
        val decision=LockScheduleDecision.evaluate(listOf(LockPlan("day","day",setOf(7),listOf(TimeRange(0,0)))),emptyList(),null,start,local)
        assertEquals(LockRun.MAX_DURATION_MS,decision.startDurationMs)
        assertEquals(1,decision.window!!.occurrenceIds.size)
    }
    @Test fun should_retryWithinWindow_when_permissionsMissing() {
        val decision=LockScheduleDecision.evaluate(listOf(plan("a",599,601)),emptyList(),null,now,zone)
        assertEquals(now+30_000,decision.retryAt)
    }
    @Test fun should_scheduleExactStart_when_planIsInFuture() {
        val decision=LockScheduleDecision.evaluate(listOf(plan("a",603,605)),emptyList(),null,now,zone)
        assertNull(decision.window)
        assertEquals(now+180_000,decision.nextStartAt)
    }
    @Test fun should_consumeCurrentOverlapOnly_when_emergencyExitIsConfirmed() {
        val plans = listOf(plan("a",590,610),plan("b",600,630),plan("future",640,650))
        val current = LockScheduleDecision.evaluate(plans.take(1),emptyList(),null,now,zone)
        val run = LockRun("","r","s",setOf("a"),current.window!!.occurrenceIds,
            now,now+600000,600000,true,600000,10,1)
        val consumed = LockScheduleDecision.emergencyOccurrences(plans,emptyList(),run,now,zone)
        assertEquals(2,consumed.size)
        val ended = run.copy(status=LockRunStatus.EMERGENCY,occurrenceIds=consumed,endedAt=now)
        assertNull(LockScheduleDecision.evaluate(plans,listOf(ended),null,now,zone).window)
        assertNotNull(LockScheduleDecision.evaluate(plans,listOf(ended),null,now+40*60_000,zone).window)
    }
}
