package io.github.nanomuse.focus.lock

import org.junit.Assert.*
import org.junit.Test

/** 闹钟触发点必须以单调剩余时间为准，旧墙钟闹钟不能结束仍有效的会话。 */
class LockAlarmPolicyTest {
    @Test fun should_projectBothClocks_when_wallClockChanges() {
        val run = LockRun("", "r", "s", emptySet(), emptySet(), 1000, 121000,
            120000, true, 120000, 500, 1)
        val normal = LockAlarmPolicy.deadlines(run, 2000, 1500, 1)
        val shifted = LockAlarmPolicy.deadlines(run, 902000, 1500, 1)
        assertEquals(normal?.elapsedEnd, shifted?.elapsedEnd)
        assertEquals(120500L, shifted?.elapsedEnd)
        assertEquals(1021000L, shifted?.wallEnd)
    }

    @Test fun should_cancelEnding_when_sessionExpiredOrFinished() {
        val run = LockRun("", "r", "s", emptySet(), emptySet(), 0, 100,
            100, true, 100, 10, 1)
        assertNull(LockAlarmPolicy.deadlines(run, 100, 110, 1))
        assertNull(LockAlarmPolicy.deadlines(run.copy(status=LockRunStatus.COMPLETED), 0, 10, 1))
    }

    @Test fun should_restoreFromFixedDeadline_when_rebooted() {
        val run = LockRun("", "r", "s", emptySet(), emptySet(), 1000, 121000,
            120000, true, 110000, 500, 1)
        val recovered = LockAlarmPolicy.deadlines(run, 61000, 100, 2)
        assertEquals(121000L, recovered?.wallEnd)
        assertEquals(60100L, recovered?.elapsedEnd)
    }
}
