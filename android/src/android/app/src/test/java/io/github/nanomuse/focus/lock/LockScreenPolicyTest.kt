package io.github.nanomuse.focus.lock

import org.junit.Assert.*
import org.junit.Test

/** 强制期间AI的屏幕操作一律拒绝，到期或未锁定时恢复。 */
class LockScreenPolicyTest {
    @Test fun should_blockEveryScreenOperation_when_locked() {
        try { LockScreenPolicy.requireAutomationAllowed(1);fail("screen operation must be refused") }
        catch(expected:FocusLockedException) { assertEquals("focus_locked",expected.message) }
    }
    @Test fun should_allowAutomation_when_expiredOrUnlocked() {
        LockScreenPolicy.requireAutomationAllowed(null);LockScreenPolicy.requireAutomationAllowed(0)
    }
}
