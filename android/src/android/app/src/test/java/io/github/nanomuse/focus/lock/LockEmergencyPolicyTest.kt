package io.github.nanomuse.focus.lock

import org.junit.Assert.*
import org.junit.Test

/** 紧急等待不能通过系统时间、页面重建或重新申请绕过。 */
class LockEmergencyPolicyTest {
    @Test fun should_requireFullTenMinutes_when_waitBegins() {
        val wait=LockEmergencyPolicy.begin("r",100,1)
        assertEquals(600_000L,LockEmergencyPolicy.remaining(wait,100,1))
        assertEquals(1L,LockEmergencyPolicy.remaining(wait,600099,1))
        assertEquals(0L,LockEmergencyPolicy.remaining(wait,600100,1))
    }
    @Test fun should_keepCheckpointRemaining_when_deviceReboots() {
        val wait=LockEmergencyPolicy.begin("r",100,1)
        val saved=LockEmergencyPolicy.checkpoint(wait,120100,1)
        assertEquals(480_000L,LockEmergencyPolicy.remaining(saved,100,2))
        val restored=LockEmergencyPolicy.checkpoint(saved,100,2)
        assertEquals(479_000L,LockEmergencyPolicy.remaining(restored,1100,2))
    }
    @Test fun should_refuseUnreadyOrOtherRun_when_confirming() {
        val wait=LockEmergencyPolicy.begin("r",100,1)
        assertFalse(LockEmergencyPolicy.canConfirm(wait,"other",600100,1))
        assertFalse(LockEmergencyPolicy.canConfirm(wait,"r",600099,1))
        assertTrue(LockEmergencyPolicy.canConfirm(wait,"r",600100,1))
    }
    @Test fun should_notCountUnknownBootAsContinuous_when_restoring() {
        val wait=LockEmergencyPolicy.begin("r",100,-1)
        assertEquals(600_000L,LockEmergencyPolicy.remaining(wait,900000,-1))
    }
}
