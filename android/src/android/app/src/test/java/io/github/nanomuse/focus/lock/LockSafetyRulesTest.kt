package io.github.nanomuse.focus.lock

import org.junit.Assert.*
import org.junit.Test

/** 开发安全阀和正式时长上限必须在创建计时记录之前校验。 */
class LockSafetyRulesTest {
    @Test fun should_acceptBoundary_when_durationWithinCap() {
        LockSafetyRules.requireDuration(1, 300_000)
        LockSafetyRules.requireDuration(300_000, 300_000)
        LockSafetyRules.requireDuration(LockRun.MAX_DURATION_MS, LockRun.MAX_DURATION_MS)
    }

    @Test fun should_refuseInvalidOrOverlong_when_startRequested() {
        listOf(0L, -1L, 300_001L, Long.MAX_VALUE).forEach { duration ->
            assertThrows(IllegalArgumentException::class.java) {
                LockSafetyRules.requireDuration(duration, 300_000)
            }
        }
        assertThrows(IllegalArgumentException::class.java) {
            LockSafetyRules.requireDuration(LockRun.MAX_DURATION_MS + 1, Long.MAX_VALUE)
        }
    }
}
