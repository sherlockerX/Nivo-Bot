package io.github.nanomuse.focus.lock

import org.junit.Assert.*
import org.junit.Test

/** 不把系统的开启开关误认为无障碍已经可用。 */
class LockPermissionStateTest {
    private val ready = LockPermissionState(30, true, true, true, true, true, true, false)
    @Test fun should_allowStart_when_allRequiredPermissionsReady() { assertTrue(ready.isReady) }
    @Test fun should_rejectStart_when_eachRequiredPermissionMissing() {
        listOf(ready.copy(sdk=29), ready.copy(isAccessibilityEnabled=false),
            ready.copy(isAccessibilityConnected=false), ready.copy(hasOverlay=false),
            ready.copy(hasUsageAccess=false), ready.copy(hasExactAlarms=false),
            ready.copy(hasNotifications=false)).forEach { assertFalse(it.isReady) }
    }
    @Test fun should_detectStaleService_when_enabledButDisconnected() {
        assertTrue(ready.copy(isAccessibilityConnected=false).isAccessibilityStale)
        assertFalse(ready.isAccessibilityStale)
        assertFalse(ready.copy(isAccessibilityEnabled=false,isAccessibilityConnected=false).isAccessibilityStale)
    }
    @Test fun should_keepBatteryAdviceOptional_when_systemAllowsStart() {
        assertTrue(ready.isReady)
        assertTrue(ready.copy(isBatteryUnrestricted=true,sdk=36).isReady)
    }
}
