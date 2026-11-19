package io.github.nanomuse.focus.lock

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** 从FocusLock当前会话计时契约移植，验证固定截止和检查点，旧墙钟优先算法不再使用。 */
class CountdownTest {
    private val startWall = 1_700_000_000_000L
    private val duration = 3_600_000L

    /** 同次启动只按单调时间扣减检查点，墙钟不参与。 */
    @Test
    fun should_useMonotonicRemaining_when_sameBootContinues() {
        assertEquals(LockRemaining(3_000_000L, false), run().remaining(startWall + 600_000L, 610_000L, 7))
    }

    /** 系统时间前调不能让同次启动的会话提前结束。 */
    @Test
    fun should_ignoreForwardWallChange_when_bootIsUnchanged() {
        assertEquals(LockRemaining(3_000_000L, false), run().remaining(Long.MAX_VALUE, 610_000L, 7))
    }

    /** 系统时间后调不能让同次启动的会话延长。 */
    @Test
    fun should_ignoreBackwardWallChange_when_bootIsUnchanged() {
        assertEquals(LockRemaining(3_000_000L, false), run().remaining(0L, 610_000L, 7))
    }

    /** 小幅校时也不增加剩余秒数。 */
    @Test
    fun should_ignoreSmallWallDrift_when_bootIsUnchanged() {
        assertEquals(LockRemaining(3_000_000L, false), run().remaining(startWall + 570_000L, 610_000L, 7))
    }

    /** 结束边界前一毫秒必须仍有剩余。 */
    @Test
    fun should_keepLastMillisecond_when_beforeDeadline() {
        assertEquals(LockRemaining(1L, false), run().remaining(0L, 3_609_999L, 7))
    }

    /** 到达固定单调截止时不继续拦截。 */
    @Test
    fun should_returnZero_when_monotonicDeadlineArrives() {
        assertEquals(LockRemaining(0L, false), run().remaining(0L, 3_610_000L, 7))
    }

    /** 超过截止后不产生负时长。 */
    @Test
    fun should_clampToZero_when_durationHasElapsed() {
        assertEquals(LockRemaining(0L, false), run().remaining(0L, Long.MAX_VALUE, 7))
    }

    /** 新启动uptime即使更大，也必须按启动身份恢复。 */
    @Test
    fun should_useFixedDeadline_when_bootChangesWithLargerUptime() {
        assertEquals(LockRemaining(1_800_000L, true), run().remaining(startWall + 1_800_000L, 700_000L, 8))
    }

    /** 未知启动编号不把旧单调读数当成连续时钟。 */
    @Test
    fun should_rebaseline_when_bootIsUnknown() {
        assertEquals(LockRemaining(1_800_000L, true), run().remaining(startWall + 1_800_000L, 700_000L, -1))
        assertEquals(LockRemaining(1_800_000L, true), run().copy(bootCount = -1)
            .remaining(startWall + 1_800_000L, 700_000L, -1))
    }

    /** 进程临时身份只供当前进程恢复后的单调计算。 */
    @Test
    fun should_keepCounting_when_unknownBootIsBoundToCurrentProcess() {
        val rebound = run().copy(bootCount = LockRun.PROCESS_BOOT_COUNT, checkpointElapsed = 200_000L)
        assertEquals(LockRemaining(3_290_000L, false), rebound.remaining(startWall, 210_000L, LockRun.PROCESS_BOOT_COUNT))
    }

    /** 单调钟回退时仍以固定截止和检查点限制恢复量。 */
    @Test
    fun should_rebaseline_when_monotonicClockMovesBackwards() {
        assertEquals(LockRemaining(600_000L, true), run().remaining(startWall + 3_000_000L, 1_000L, 7))
    }

    /** 到期后重启不得补锁。 */
    @Test
    fun should_expire_when_restoredAfterWallDeadline() {
        assertEquals(LockRemaining(0L, true), run().remaining(startWall + duration + 1L, 1_000L, 8))
    }

    /** 跨启动恰好到截止时也不能再追加检查点。 */
    @Test
    fun should_expire_when_restoredAtExactWallDeadline() {
        assertEquals(LockRemaining(0L, true), run().remaining(startWall + duration, 1_000L, 8))
    }

    /** 跨启动墙钟回拨的恢复量最多为保存的检查点。 */
    @Test
    fun should_capAtCheckpoint_when_rebootWallClockRollsBack() {
        assertEquals(LockRemaining(3_300_000L, true), run().remaining(startWall - 7_200_000L, 1_000L, 8))
    }

    /** 极端负墙钟不能溢出而提前结束，仍使用检查点上限。 */
    @Test
    fun should_avoidSubtractionOverflow_when_wallClockIsExtreme() {
        assertEquals(LockRemaining(3_300_000L, true), run().remaining(Long.MIN_VALUE, 1_000L, 8))
    }

    /** 已保存零检查点不能被任何启动身份复活。 */
    @Test
    fun should_preserveZeroCheckpoint_when_clockAndBootChange() {
        val ended = run().copy(checkpointRemainingMs = 0L)
        assertEquals(0L, ended.remaining(0L, 1_000L, 8).milliseconds)
        assertEquals(0L, ended.remaining(0L, 610_000L, 7).milliseconds)
    }

    /** 已结束和紧急结束的记录都不能重新进入拦截。 */
    @Test
    fun should_returnZero_when_statusIsNotActive() {
        for (status in listOf(LockRunStatus.COMPLETED, LockRunStatus.EMERGENCY)) {
            assertEquals(0L, run().copy(status = status).remaining(0L, 1_000L, 8).milliseconds)
        }
    }

    /** 检查点重建不会改变最初的结束约定和会话身份。 */
    @Test
    fun should_keepOriginalDeadline_when_restoredTwice() {
        val original = run()
        val first = original.remaining(startWall + 1_800_000L, 20_000L, 8)
        val rebased = original.copy(checkpointRemainingMs = first.milliseconds, checkpointElapsed = 20_000L, bootCount = 8)
        assertEquals(original.deadlineAt, rebased.deadlineAt)
        assertEquals(original.id, rebased.id)
        assertEquals(original.durationMs, rebased.durationMs)
        assertEquals(LockRemaining(600_000L, true), rebased.remaining(startWall + 3_000_000L, 5_000L, 9))
    }

    /** 无检查点的新会话从完整固定时长开始。 */
    @Test
    fun should_startWithFullDuration_when_newRunIsCreated() {
        val fresh = run().copy(checkpointRemainingMs = duration, checkpointElapsed = 10_000L)
        assertEquals(LockRemaining(duration, false), fresh.remaining(startWall, 10_000L, 7))
    }

    /** 单次锁定上限包含恰好24小时。 */
    @Test
    fun should_allowTwentyFourHours_when_durationIsAtLimit() {
        val longest = run().copy(durationMs = LockRun.MAX_DURATION_MS,
            deadlineAt = startWall + LockRun.MAX_DURATION_MS)
        assertTrue(longest.durationMs == 86_400_000L)
    }

    /** 超过上限不能创建会话。 */
    @Test(expected = IllegalArgumentException::class)
    fun should_rejectLongDuration_when_moreThanTwentyFourHours() {
        run().copy(durationMs = LockRun.MAX_DURATION_MS + 1L)
    }

    /** 非正时长不能创建活动锁定。 */
    @Test(expected = IllegalArgumentException::class)
    fun should_rejectZeroDuration_when_creatingRun() {
        run().copy(durationMs = 0L, checkpointRemainingMs = 0L)
    }

    /** 无法从超出总时长的损坏检查点恢复。 */
    @Test(expected = IllegalArgumentException::class)
    fun should_rejectInvalidCheckpoint_when_remainingExceedsDuration() {
        run().copy(checkpointRemainingMs = duration + 1L)
    }

    /** 损坏的固定截止不能让同次启动与重启后的计时各自采用不同约定。 */
    @Test
    fun should_rejectInconsistentDeadline_when_fixedDurationDoesNotMatch() {
        for (deadline in listOf(startWall - 1L, startWall, startWall + 1L, startWall + duration + 1L)) {
            org.junit.Assert.assertThrows(IllegalArgumentException::class.java) {
                run().copy(deadlineAt = deadline)
            }
        }
    }

    /** 截止计算溢出也属于无效记录，不能绕回过去。 */
    @Test(expected = IllegalArgumentException::class)
    fun should_rejectOverflowingDeadline_when_startIsNearLongMaximum() {
        run().copy(startedAt = Long.MAX_VALUE - 1L, deadlineAt = Long.MIN_VALUE)
    }

    /** 检查点缺损不能产生负剩余量。 */
    @Test(expected = IllegalArgumentException::class)
    fun should_rejectNegativeCheckpoint_when_recordIsDamaged() {
        run().copy(checkpointRemainingMs = -1L)
    }

    /** 非法单调采样不能参与减法，改走有界恢复。 */
    @Test
    fun should_rebaseline_when_monotonicSampleIsNegative() {
        assertEquals(LockRemaining(1_800_000L, true),
            run().remaining(startWall + 1_800_000L, Long.MIN_VALUE, 7))
    }

    private fun run() = LockRun(
        ownerKey = "test-owner", id = "run", sessionId = "focus-session",
        planIds = setOf("plan"), occurrenceIds = setOf("occurrence"),
        startedAt = startWall, deadlineAt = startWall + duration, durationMs = duration,
        usesWhitelist = true, checkpointRemainingMs = 3_300_000L,
        checkpointElapsed = 310_000L, bootCount = 7
    )
}
