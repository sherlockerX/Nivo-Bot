package io.github.nanomuse.focus.lock

import org.junit.Assert.assertEquals
import org.junit.Test

/** 输入法切换以系统当前身份为准，旧缓存不能扩大Activity访问范围。 */
class LockInputMethodRefreshTest {
    private val access = LockAccessPolicy.Context("own", "own.Lock", setOf("phone"),
        "old.keyboard", emptySet(), emptySet(), emptySet(), emptySet(), false)

    @Test fun should_allowNewKeyboard_when_systemInputMethodChanges() {
        assertEquals(LockAccessPolicy.Decision.ALLOW, decide("new.keyboard", "new.keyboard"))
    }

    @Test fun should_rejectOldKeyboard_when_systemInputMethodChanges() {
        assertEquals(LockAccessPolicy.Decision.BLOCK, decide("old.keyboard", "new.keyboard"))
    }

    @Test fun should_revokeCachedKeyboard_when_currentIdentityIsUnavailable() {
        assertEquals(LockAccessPolicy.Decision.BLOCK, decide("old.keyboard", null))
    }

    @Test fun should_rejectKeyboardSettings_when_packageMatchesCurrentKeyboard() {
        val settings = LockAccessPolicy.Foreground("new.keyboard", "new.keyboard.Settings")
        assertEquals(LockAccessPolicy.Decision.BLOCK,
            LockAccessPolicy.decide(access, settings, true, 1000, "new.keyboard"))
    }

    @Test fun should_expireFirst_when_newKeyboardArrivesAfterDeadline() {
        assertEquals(LockAccessPolicy.Decision.EXPIRED,
            LockAccessPolicy.decide(access, inputWindow("new.keyboard"), true, 0, "new.keyboard"))
    }

    @Test fun should_keepPhoneAccess_when_currentInputMethodCannotBeResolved() {
        assertEquals(LockAccessPolicy.Decision.ALLOW,
            LockAccessPolicy.decide(access, LockAccessPolicy.Foreground("phone"), true, 1000, null))
    }

    private fun decide(packageName: String, currentIme: String?) =
        LockAccessPolicy.decide(access, inputWindow(packageName), true, 1000, currentIme)

    private fun inputWindow(packageName: String) = LockAccessPolicy.Foreground(packageName,
        windowKind = LockAccessPolicy.WindowKind.INPUT_METHOD, isActivity = false)
}
