package io.github.nanomuse.focus.lock

import org.junit.Assert.*
import org.junit.Test

/** 重复结算、时钟变化和恢复时不得虚增专注账本。 */
class LockAccountingTest {
    private val run = LockRun("owner", "run", "session", emptySet(), emptySet(), 100_000,
        220_000, 120_000, true, 120_000, 1_000, 3)

    @Test fun should_checkpointOnce_when_fifteenSecondsPass() {
        val result = LockAccounting.settle(run, 0, 115_000, 16_000, 3)
        assertEquals(15_000L, result.deltaMs)
        assertEquals(105_000L, result.remainingMs)
        assertTrue(result.shouldCheckpoint)
        assertFalse(result.isFinished)
        assertEquals(0L, LockAccounting.settle(run, 15_000, 115_000, 16_000, 3).deltaMs)
    }

    @Test fun should_notWriteEveryTick_when_checkpointIsFresh() {
        val result = LockAccounting.settle(run, 0, 101_000, 2_000, 3)
        assertEquals(1_000L, result.totalMs)
        assertFalse(result.shouldCheckpoint)
    }

    @Test fun should_ignoreWallClockChanges_when_sameBoot() {
        assertEquals(LockAccounting.settle(run, 0, 101_000, 2_000, 3),
            LockAccounting.settle(run, 0, 1_000_000, 2_000, 3))
    }

    @Test fun should_finishAtOriginalDuration_when_callbackIsLate() {
        val result = LockAccounting.settle(run, 15_000, 400_000, 301_000, 3)
        assertEquals(120_000L, result.totalMs)
        assertEquals(105_000L, result.deltaMs)
        assertTrue(result.isFinished)
        assertTrue(result.shouldCheckpoint)
    }

    @Test fun should_rebaselineAfterReboot_when_deadlineStillPending() {
        val result = LockAccounting.settle(run, 15_000, 150_000, 500, 4)
        assertEquals(70_000L, result.remainingMs)
        assertEquals(35_000L, result.deltaMs)
        assertTrue(result.shouldCheckpoint)
    }

    /** 越界的已记时长按边界结算，不能抛异常让锁过了截止仍解不开。 */
    @Test fun should_clampCorruptRecordedDuration_when_outsideSession() {
        val low = LockAccounting.settle(run, -1L, 100_000, 1_000, 3)
        assertTrue(low.totalMs in 0..run.durationMs)
        val high = LockAccounting.settle(run, 120_001L, 100_000, 1_000, 3)
        assertEquals(run.durationMs, high.totalMs)
        assertEquals(0L, high.remainingMs)
        assertTrue(high.isFinished)
    }
}
