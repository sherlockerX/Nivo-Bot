package io.github.nanomuse.focus.lock

import org.junit.Assert.*
import org.junit.Test

/** 亮屏恢复不能打断通话和用户已获准使用的应用。 */
class LockWakePolicyTest {
    private val access = LockAccessPolicy.Context("nivo", "LockActivity",
        setOf("phone"), "ime", setOf("launcher"), emptySet(), emptySet(), setOf("reader"), true)

    @Test fun should_keepCallVisible_when_wakingDuringPhoneActivity() {
        assertFalse(LockWakePolicy.shouldRestore(true, access, LockAccessPolicy.Foreground("phone"), 1000))
    }
    @Test fun should_keepAllowedAppVisible_when_wakingWithWhitelist() {
        assertFalse(LockWakePolicy.shouldRestore(true, access, LockAccessPolicy.Foreground("reader"), 1000))
    }
    @Test fun should_restoreLock_when_wakingOnLauncherOrWithoutForeground() {
        assertTrue(LockWakePolicy.shouldRestore(true, access, LockAccessPolicy.Foreground("launcher"), 1000))
        assertTrue(LockWakePolicy.shouldRestore(true, access, null, 1000))
    }
    @Test fun should_doNothing_when_disabledOrExpired() {
        assertFalse(LockWakePolicy.shouldRestore(false, access, null, 1000))
        assertFalse(LockWakePolicy.shouldRestore(true, access, null, 0))
    }
}
