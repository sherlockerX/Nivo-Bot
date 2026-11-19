package io.github.nanomuse.focus.lock

import org.junit.Assert.*
import org.junit.Test

/** 移植FocusLock前台决策用例，使用Nivo共享的纯放行策略。 */
class ForegroundDecisionTest {
    private val context = LockAccessPolicy.Context("own", "own.Lock", setOf("dialer"),
        "keyboard", setOf("home"), setOf("installer"), setOf("assistant"), setOf("study"), true)

    @Test fun should_allowOnlyLockActivity_when_namespaceDiffersFromPackage() {
        assertEquals(LockAccessPolicy.Decision.ALLOW, decide("own", "own.Lock"))
        assertEquals(LockAccessPolicy.Decision.BLOCK, decide("own", "own.Main"))
    }
    @Test fun should_rejectKeyboardActivity_when_onlyInputWindowIsImplicit() {
        assertEquals(LockAccessPolicy.Decision.BLOCK, decide("keyboard", "keyboard.Settings"))
        assertEquals(LockAccessPolicy.Decision.ALLOW, LockAccessPolicy.decide(context,
            LockAccessPolicy.Foreground("keyboard", windowKind = LockAccessPolicy.WindowKind.INPUT_METHOD), true, 100))
    }
    @Test fun should_keepBlocking_when_forbiddenActivityStillForeground() {
        repeat(2) { assertEquals(LockAccessPolicy.Decision.BLOCK, decide("video", "video.Main")) }
    }
    @Test fun should_allowWhitelistPhoneAndSystemWindows_when_active() {
        assertEquals(LockAccessPolicy.Decision.ALLOW, decide("study", "study.Main"))
        assertEquals(LockAccessPolicy.Decision.ALLOW, decide("dialer", "dialer.Main"))
        assertEquals(LockAccessPolicy.Decision.ALLOW, LockAccessPolicy.decide(context,
            LockAccessPolicy.Foreground("com.android.systemui", isActivity = false), true, 100))
    }
    @Test fun should_expireBeforeBlock_when_deadlinePassed() {
        assertEquals(LockAccessPolicy.Decision.EXPIRED, LockAccessPolicy.decide(context,
            LockAccessPolicy.Foreground("home"), true, 0))
    }
    private fun decide(pkg: String, cls: String) = LockAccessPolicy.decide(context,
        LockAccessPolicy.Foreground(pkg, cls), true, 100)
}
