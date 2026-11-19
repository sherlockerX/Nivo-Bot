package io.github.nanomuse.focus.lock

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** 进程时钟基准不随事务中的临时检查点变化，回滚后仍只信单调推进。 */
class LockProcessClocksTest {
    /** 没有本进程基准的持久记录保持未知启动，交由恢复策略重新建立检查点。 */
    @Test
    fun should_keepUnknownBoot_when_noAnchorExists() {
        val persisted = run().copy(bootCount = -1)
        val restored = LockProcessClocks().restore(persisted)
        assertEquals(persisted, restored)
        assertTrue(restored.remaining(2000L, 3000L, LockRun.PROCESS_BOOT_COUNT).requiresRebaseline)
    }

    /** 只接受进程临时启动号，其他启动号不能给未知持久记录伪造进程身份。 */
    @Test
    fun should_ignoreNonProcessBoot_when_remembering() {
        for (boot in listOf(-1, 0, 3)) {
            val clocks = LockProcessClocks()
            clocks.remember(run().copy(bootCount = boot))
            val persisted = run().copy(bootCount = -1)
            assertEquals(persisted, clocks.restore(persisted))
        }
    }

    /** 已知本进程基准恢复后无需墙钟，即使墙钟已超过截止也继续正确倒计时。 */
    @Test
    fun should_restoreFirstAnchor_when_wallClockMovedPastDeadline() {
        val clocks = LockProcessClocks()
        val original = run()
        clocks.remember(original)
        val restored = clocks.restore(original.copy(bootCount = -1))
        val remaining = restored.remaining(3_601_000L, 22_000L, LockRun.PROCESS_BOOT_COUNT)
        assertEquals(40_000L, remaining.milliseconds)
        assertFalse(remaining.requiresRebaseline)
    }

    /** 回滚到旧检查点时必须继续使用首次基准，不依赖最后一次临时写入是否提交。 */
    @Test
    fun should_keepOriginalAnchor_when_checkpointTransactionRollsBack() {
        val clocks = LockProcessClocks()
        val original = run()
        clocks.remember(original)
        clocks.remember(original.copy(checkpointRemainingMs = 40_000L, checkpointElapsed = 22_000L))
        val restored = clocks.restore(original.copy(bootCount = -1))
        assertEquals(original.checkpointRemainingMs, restored.checkpointRemainingMs)
        assertEquals(original.checkpointElapsed, restored.checkpointElapsed)
        assertEquals(40_000L, restored.remaining(3_601_000L, 22_000L, LockRun.PROCESS_BOOT_COUNT).milliseconds)
    }

    /** 完成状态的临时写入被回滚时，原活动记录仍可找到进程基准。 */
    @Test
    fun should_retainAnchor_when_completionWriteWasRolledBack() {
        val clocks = LockProcessClocks()
        val original = run()
        clocks.remember(original)
        clocks.remember(original.copy(
            checkpointRemainingMs = 0L, checkpointElapsed = 62_000L,
            status = LockRunStatus.COMPLETED, endedAt = original.deadlineAt
        ))
        val restored = clocks.restore(original.copy(bootCount = -1))
        assertEquals(original, restored)
    }

    /** 恢复只覆盖检查点和临时启动号，其余字段始终使用最新持久记录。 */
    @Test
    fun should_preserveLatestRunFields_when_restoringAnchor() {
        val clocks = LockProcessClocks()
        clocks.remember(run())
        val latest = run().copy(
            sessionId = "latest-session", planIds = setOf("latest-plan"),
            occurrenceIds = setOf("latest-occurrence"), usesWhitelist = false,
            deadlineAt = 121_000L, durationMs = 120_000L,
            checkpointRemainingMs = 10_000L, checkpointElapsed = 52_000L,
            bootCount = -1, status = LockRunStatus.EMERGENCY, endedAt = 51_000L
        )
        val restored = clocks.restore(latest)
        assertEquals(latest.copy(
            checkpointRemainingMs = 60_000L, checkpointElapsed = 2_000L,
            bootCount = LockRun.PROCESS_BOOT_COUNT
        ), restored)
        assertEquals(0L, restored.remaining(55_000L, 56_000L, LockRun.PROCESS_BOOT_COUNT).milliseconds)
    }

    /** 相同运行身份在不同账号中不能共享单调检查点。 */
    @Test
    fun should_isolateOwners_when_runIdsMatch() {
        val clocks = LockProcessClocks()
        clocks.remember(run())
        val other = run().copy(ownerKey = "other-owner", bootCount = -1)
        assertEquals(other, clocks.restore(other))
        clocks.remember(other.copy(
            bootCount = LockRun.PROCESS_BOOT_COUNT,
            checkpointRemainingMs = 20_000L, checkpointElapsed = 42_000L
        ))
        assertEquals(60_000L, clocks.restore(run().copy(bootCount = -1)).checkpointRemainingMs)
        assertEquals(20_000L, clocks.restore(other).checkpointRemainingMs)
    }

    /** 同一账号的下一次运行不能复用上一次运行的检查点。 */
    @Test
    fun should_isolateRuns_when_ownerMatches() {
        val clocks = LockProcessClocks()
        clocks.remember(run())
        val other = run().copy(id = "other-run", bootCount = -1)
        assertEquals(other, clocks.restore(other))
    }

    /** 系统重新提供真实启动号时，持久记录中的已知启动信息优先。 */
    @Test
    fun should_preserveKnownBoot_when_persistedRunHasRealBootCount() {
        val clocks = LockProcessClocks()
        clocks.remember(run())
        val persisted = run().copy(
            bootCount = 7, checkpointRemainingMs = 40_000L, checkpointElapsed = 22_000L
        )
        assertEquals(persisted, clocks.restore(persisted))
    }

    /** 新进程实例不携带旧内存基准，必须走持久检查点恢复。 */
    @Test
    fun should_forgetAnchorAcrossInstances_when_processRestarts() {
        val first = LockProcessClocks()
        first.remember(run())
        val persisted = run().copy(bootCount = -1)
        assertEquals(LockRun.PROCESS_BOOT_COUNT, first.restore(persisted).bootCount)
        assertEquals(persisted, LockProcessClocks().restore(persisted))
    }

    private fun run() = LockRun(
        ownerKey = "owner", id = "run", sessionId = "session",
        planIds = setOf("plan"), occurrenceIds = setOf("occurrence"),
        startedAt = 1000L, deadlineAt = 61_000L, durationMs = 60_000L,
        usesWhitelist = true, checkpointRemainingMs = 60_000L,
        checkpointElapsed = 2000L, bootCount = LockRun.PROCESS_BOOT_COUNT
    )
}
