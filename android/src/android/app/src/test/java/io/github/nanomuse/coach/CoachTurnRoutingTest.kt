package io.github.nanomuse.coach

import org.junit.Assert.*
import org.junit.Test

/** 验证教练语音约束绑定具体消息，不泄漏到后续普通聊天。 */
class CoachTurnRoutingTest {
    @Test fun should_authorize_only_host_bound_practice_conversations() {
        val routing = CoachTurnRouting()
        routing.authorize("practice-user", "practice-chat")
        assertNull(routing.denialReason("practice-user", "practice-chat", false, false, false, true,
            isBoundPractice = true))
        assertEquals("main_required", routing.denialReason("practice-user", "practice-chat", false, false, false, true))
        assertEquals("user_turn_required", routing.denialReason("practice-user", "other-chat", false, false, false, true,
            isBoundPractice = true))
        assertEquals("scheduled_forbidden", routing.denialReason("practice-user", "practice-chat", false, true, false, true,
            isBoundPractice = true))
        assertEquals("dispatch_forbidden", routing.denialReason("practice-user", "practice-chat", false, false, true, true,
            isBoundPractice = true))
    }

    @Test fun should_keep_bound_practice_permission_scoped_to_authorized_background_turn() {
        val routing = CoachTurnRouting()
        val authorization = routing.authorize("user-1", "practice-chat")!!
        assertNull(routing.denialReason("user-1", "practice-chat", false, false, false, false, isBoundPractice = true))
        routing.revoke(authorization)
        assertEquals("foreground_required", routing.denialReason("user-1", "practice-chat", false, false, false, false,
            isBoundPractice = true))
    }

    @Test fun should_keep_retry_authorization_when_old_loop_revokes_same_user() {
        val routing = CoachTurnRouting()
        val oldAuthorization = routing.authorize("same-user", "main-1")!!
        val oldRevoke = { routing.revoke(oldAuthorization) }
        routing.authorize("same-user", "main-1")
        oldRevoke()
        assertNull(routing.denialReason("same-user", "main-1", true, false, false, false))
    }

    @Test fun should_keep_only_the_authorized_user_turn_available_in_background() {
        val routing = CoachTurnRouting()
        routing.authorize("user-1", "main-1")
        assertNull(routing.denialReason("user-1", "main-1", true, false, false, false))
        assertEquals("foreground_required", routing.denialReason("user-2", "main-1", true, false, false, false))
        assertEquals("user_turn_required", routing.denialReason("user-2", "main-1", true, false, false, true))
        assertEquals("main_required", routing.denialReason("user-1", "main-1", false, false, false, false))
        assertEquals("scheduled_forbidden", routing.denialReason("user-1", "main-1", true, true, false, false))
        assertEquals("dispatch_forbidden", routing.denialReason("user-1", "main-1", true, false, true, false))
        routing.revoke(routing.currentAuthorization("user-1")!!)
        assertEquals("foreground_required", routing.denialReason("user-1", "main-1", true, false, false, false))
    }

    @Test fun should_mark_only_assistants_linked_to_coach_user_or_successful_tool() {
        val routing = CoachTurnRouting()
        routing.markUser("user-coach")
        routing.beginAssistant("assistant-coach", "user-coach")
        routing.beginAssistant("assistant-normal", "user-normal")
        assertTrue(routing.isCoach("assistant-coach"))
        assertFalse(routing.isCoach("assistant-normal"))
        routing.markAssistant("assistant-tools")
        assertTrue(routing.isCoach("assistant-tools"))
        assertFalse(routing.isCoach("unrelated"))
    }

    @Test fun should_keep_same_user_retry_coach_but_clear_on_viewmodel_disposal() {
        val routing = CoachTurnRouting()
        routing.markUser("user-coach")
        routing.beginAssistant("first", "user-coach")
        routing.beginAssistant("retry", "user-coach")
        assertTrue(routing.isCoach("retry"))
        routing.clear()
        assertFalse(routing.isCoach("first"))
        routing.beginAssistant("later", "user-coach")
        assertFalse(routing.isCoach("later"))
    }

    @Test fun should_gate_coach_to_main_user_turns_without_background_dispatch() {
        assertTrue(CoachTurnRouting.canAccess(true, false, false, true))
        assertFalse(CoachTurnRouting.canAccess(false, false, false, true))
        assertFalse(CoachTurnRouting.canAccess(true, true, false, true))
        assertFalse(CoachTurnRouting.canAccess(true, false, true, true))
        assertFalse(CoachTurnRouting.canAccess(true, false, false, false))
        assertFalse(CoachTurnRouting.canAccess(true, false, false, true, false))
    }
}
