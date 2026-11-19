package io.github.nanomuse.focus.lock

import org.junit.Assert.*
import org.junit.Test

/** 完成通知依据实际结束转换，不受用户修改墙钟影响。 */
class LockCompletionPolicyTest {
    @Test fun should_notifyObservedCompletion_when_wallClockMovesBackward() {
        assertTrue(eligible(LockRunStatus.COMPLETED, "run", 60_000, 0, "run"))
    }
    @Test fun should_notifyObservedCompletion_when_wallClockMovesForward() {
        assertTrue(eligible(LockRunStatus.COMPLETED, "run", 60_000, 900_000, "run"))
    }
    @Test fun should_notReplayOldHistory_when_noActiveTransitionWasObserved() {
        assertFalse(eligible(LockRunStatus.COMPLETED, "run", 60_000, 900_000, null))
        assertFalse(eligible(LockRunStatus.COMPLETED, "old", 60_000, 900_000, "new"))
    }
    @Test fun should_notifyRecentCompletion_when_processRestarts() {
        assertTrue(eligible(LockRunStatus.COMPLETED, "run", 60_000, 60_001, null))
    }
    @Test fun should_notNotifyCompletion_when_stillActiveOrEmergency() {
        assertFalse(eligible(LockRunStatus.ACTIVE, "run", null, 60_000, "run"))
        assertFalse(eligible(LockRunStatus.EMERGENCY, "run", 60_000, 60_001, "run"))
    }
    @Test fun should_notNotifyMissingOrFutureHistory_when_noTransitionWasObserved() {
        assertFalse(eligible(LockRunStatus.COMPLETED, "run", null, 60_000, "run"))
        assertFalse(eligible(LockRunStatus.COMPLETED, "run", 60_000, 0, null))
    }

    private fun eligible(status: LockRunStatus, id: String, endedAt: Long?, now: Long, previous: String?) =
        LockCompletionPolicy.shouldNotify(status, id, endedAt, now, previous)
}
