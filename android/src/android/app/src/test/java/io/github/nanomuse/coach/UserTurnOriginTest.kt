package io.github.nanomuse.coach

import org.junit.Assert.*
import org.junit.Test

/** 验证用户来源跨异步等待仍固定到原宿主，后台调用不能借用前台应用状态。 */
class UserTurnOriginTest {
    private fun capture(session: String = "chat", retry: String? = null,
        isForeground: Boolean = true, isDispatch: Boolean = false): UserTurnOrigin? =
        UserTurnOrigin.capture(session, session, retry, isForeground, true, true, isDispatch)

    @Test fun should_rejectHeadlessEvenWhileForeground() {
        assertNull(capture(isDispatch = true))
        assertNull(capture(isForeground = false))
        assertNotNull(capture())
    }

    @Test fun should_allowFirstDraftPromotionOnlyWithinSameHost() {
        val origin = capture("__new__draft")!!
        assertTrue(origin.canBind("__new__draft", "persisted-chat", "saved-user", true, true, false))
        assertFalse(origin.canBind("another-host", "persisted-chat", "saved-user", true, true, false))
        assertFalse(capture()!!.canBind("chat", "another-chat", "saved-user", true, true, false))
    }

    @Test fun should_keepForegroundOriginAfterWaitingWithoutRecheckingForeground() {
        val origin = capture()!!
        assertTrue(origin.canBind("chat", "chat", "saved-user", true, true, false))
        assertFalse(origin.canBind("chat", "chat", "saved-user", false, true, false))
        assertFalse(origin.canBind("chat", "chat", "saved-user", true, false, false))
        assertFalse(origin.canBind("chat", "chat", "saved-user", true, true, true))
    }

    @Test fun should_bindRetryToOriginalSavedMessage() {
        val origin = capture(retry = "original-user")!!
        assertTrue(origin.canBind("chat", "chat", "original-user", true, true, false))
        assertFalse(origin.canBind("chat", "chat", "new-user", true, true, false))
        assertFalse(origin.canBind("chat", "chat", "queued_msg_old", true, true, false))
    }

    @Test fun should_denyMixedUserAndHeadlessQueueBatch() {
        val origin = capture()!!
        assertEquals(origin, UserTurnOrigin.merged(listOf(origin, origin.copy())))
        assertNull(UserTurnOrigin.merged(listOf(origin, null)))
        assertNull(UserTurnOrigin.merged(listOf(origin, capture("another-chat"))))
        assertNull(UserTurnOrigin.merged(emptyList()))
    }

    @Test fun should_revokeOnlyOwnRetryTokenAndKeepCoachScopeRestricted() {
        val routing = CoachTurnRouting()
        val initial = routing.authorize("original-user", "chat")!!
        val retry = routing.authorize("original-user", "chat")!!
        routing.revoke(initial)
        assertEquals(retry, routing.currentAuthorization("original-user"))
        assertEquals("main_required", routing.denialReason("original-user", "chat", false, false, false, false))
        routing.revoke(retry)
        assertNull(routing.currentAuthorization("original-user"))
    }
}
