package io.github.nanomuse.focus.lock

import org.junit.Assert.*
import org.junit.Test

/** 入口安全边界独立于Android和按钮状态进行回归。 */
class LockMutationPolicyTest {
    @Test fun should_rejectAllTimerMutations_when_lockIsActive() {
        listOf("start", "pause", "resume", "finish", "delete").forEach { action ->
            val error = runCatching { LockMutationPolicy.requireCommandAllowed(action, 1L) }.exceptionOrNull()
            assertTrue(action, error is FocusLockedException)
            assertEquals("focus_locked", error?.message)
        }
    }

    @Test fun should_keepOrdinaryCommands_when_lockIsAbsentOrExpired() {
        listOf(null, 0L, -1L).forEach { remaining ->
            listOf("start", "pause", "resume", "finish", "delete").forEach {
                LockMutationPolicy.requireCommandAllowed(it, remaining)
            }
        }
    }

    @Test fun should_rejectEditingActivePlan_when_otherPlansRemainEditable() {
        assertTrue(runCatching { LockMutationPolicy.requirePlanEditable("active", setOf("active")) }.exceptionOrNull() is FocusLockedException)
        LockMutationPolicy.requirePlanEditable("future", setOf("active"))
    }

    @Test fun should_onlyAllowTightening_when_locked() {
        LockMutationPolicy.requireWhitelistChange(setOf("one", "two"), setOf("one"), true)
        LockMutationPolicy.requireWhitelistChange(setOf("one"), setOf("one"), true)
        assertTrue(runCatching {
            LockMutationPolicy.requireWhitelistChange(setOf("one"), setOf("one", "two"), true)
        }.exceptionOrNull() is FocusLockedException)
        assertTrue(runCatching {
            LockMutationPolicy.requireWhitelistChange(setOf("one"), setOf("two"), true)
        }.exceptionOrNull() is FocusLockedException)
        LockMutationPolicy.requireWhitelistChange(emptySet(), setOf("two"), false)
    }
}
