package io.github.nanomuse.coach

import org.junit.Assert.*
import org.junit.Test

/** 防止普通聊天占用、纯文字回复和失败重试把训练永久锁在等待状态。 */
class CoachRequestTrackerTest {
    private fun snapshot(stage: String = "first", pending: String? = "answer-1") =
        CoachRequestSnapshot("session-1", stage, pending, 2)

    @Test fun should_reject_busy_chat_without_starting_or_cancelling_it() {
        val tracker = CoachRequestTracker()
        assertFalse(tracker.begin("session-1", snapshot(), busy = true))
        assertFalse(tracker.state.value!!.isRunning)
        assertEquals("chat_busy", tracker.state.value!!.reason)
    }

    @Test fun should_fail_when_final_text_does_not_commit_pending_answer() {
        val tracker = CoachRequestTracker()
        tracker.begin("session-1", snapshot())
        tracker.bindUser("user-1")
        tracker.finish(tracker.ownerForUser("user-1"), snapshot())
        assertFalse(tracker.state.value!!.isRunning)
        assertEquals("reply_not_saved", tracker.state.value!!.reason)
        assertTrue(tracker.state.value!!.canRetry)
    }

    @Test fun should_require_setup_scene_to_be_saved() {
        val tracker = CoachRequestTracker()
        tracker.begin("session-1", snapshot("setup", null))
        tracker.bindUser("user-1")
        tracker.finish(tracker.ownerForUser("user-1"), snapshot("setup", null))
        assertEquals("reply_not_saved", tracker.state.value!!.reason)
    }

    @Test fun should_finish_after_matching_reply_and_allow_retry_after_failure() {
        val tracker = CoachRequestTracker()
        tracker.begin("session-1", snapshot())
        tracker.bindUser("first")
        tracker.toolFailure("first", "foreground", "前台验证失败")
        tracker.finish(tracker.ownerForUser("first"), snapshot())
        assertEquals("前台验证失败", tracker.state.value!!.error)
        assertTrue(tracker.begin("session-1", snapshot()))
        tracker.bindUser("retry")
        tracker.finish(tracker.ownerForUser("first"), snapshot())
        assertTrue(tracker.state.value!!.isRunning)
        tracker.finish(tracker.ownerForUser("retry"), snapshot("probe", null))
        assertNull(tracker.state.value!!.error)
        assertFalse(tracker.state.value!!.isRunning)
    }

    @Test fun should_not_let_ordinary_queries_inherit_a_training_target() {
        val tracker = CoachRequestTracker()
        tracker.observe("user-1", null, null)
        tracker.finish(tracker.ownerForUser("user-1"), null)
        assertNull(tracker.state.value!!.sessionId)
        assertNull(tracker.state.value!!.error)
    }

    @Test fun should_preserve_pending_answer_when_cancelled() {
        val tracker = CoachRequestTracker()
        tracker.begin("session-1", snapshot())
        tracker.bindUser("user-1")
        tracker.finish(tracker.ownerForUser("user-1"), snapshot(), cancelled = true)
        assertEquals("cancelled", tracker.state.value!!.reason)
        assertTrue(tracker.state.value!!.canRetry)
    }

    @Test fun should_require_reply_after_natural_language_answer_command() {
        val tracker = CoachRequestTracker()
        tracker.observe("user-1", null, null)
        tracker.expectReply("user-1", snapshot())
        tracker.finish(tracker.ownerForUser("user-1"), snapshot())
        assertEquals("reply_not_saved", tracker.state.value!!.reason)
    }

    @Test fun should_keep_ordinary_queries_from_clearing_a_failed_mutation() {
        val tracker = CoachRequestTracker()
        tracker.observe("user-1", null, null)
        tracker.toolFailure("user-1", "activation_failed", "课程提案版本已过期", "activate:draft-1:op-1")
        tracker.toolSuccess("user-1", null)
        tracker.finish(tracker.ownerForUser("user-1"), null)
        assertEquals("课程提案版本已过期", tracker.state.value!!.error)
        assertEquals("activation_failed", tracker.state.value!!.reason)
    }

    @Test fun should_keep_coach_reply_error_after_a_successful_query() {
        val tracker = CoachRequestTracker()
        tracker.begin("session-1", snapshot())
        tracker.bindUser("user-1")
        tracker.toolFailure("user-1", "reply_not_saved", "coach_reply未提交", "coach_reply:session-1:op-2")
        tracker.toolSuccess("user-1", null)
        tracker.finish(tracker.ownerForUser("user-1"), snapshot())
        assertEquals("coach_reply未提交", tracker.state.value!!.error)
    }

    @Test fun should_keep_request_identity_while_waiting_for_compact_confirmation() {
        val tracker = CoachRequestTracker()
        assertTrue(tracker.begin("session-1", snapshot()))
        val requestId = tracker.state.value!!.requestId
        tracker.awaitConfirmation()
        assertTrue(tracker.state.value!!.isRunning)
        assertTrue(tracker.state.value!!.isAwaitingConfirmation)
        assertEquals("session-1", tracker.state.value!!.sessionId)
        assertEquals(requestId, tracker.state.value!!.requestId)
        assertFalse(tracker.begin("session-1", snapshot()))
        tracker.cancelAwaiting()
        assertFalse(tracker.state.value!!.isRunning)
        assertFalse(tracker.state.value!!.isAwaitingConfirmation)
        assertEquals("cancelled", tracker.state.value!!.reason)
    }

    @Test fun should_clear_only_the_matching_mutation_failure() {
        val tracker = CoachRequestTracker()
        tracker.observe("user-1", null, null)
        tracker.toolFailure("user-1", "activation_failed", "旧提案", "activate:draft-1:op-1")
        tracker.toolSuccess("user-1", "activate:draft-1:op-2")
        tracker.finish(tracker.ownerForUser("user-1"), null)
        assertEquals("旧提案", tracker.state.value!!.error)
    }

    @Test fun should_revoke_injected_user_without_any_coach_tool() {
        val finished = mutableListOf<String?>()
        val revoked = mutableListOf<String>()
        val loop = CoachRequestLoop("first", { finished += it.userId }, { revoked += it.messageId },
            CoachRequestOwner("request-first", "first"), CoachTurnAuthorization("first", "main"))
        loop.replaceUser("queued", CoachTurnAuthorization("queued", "main"))
        loop.bindRequest(CoachRequestOwner("request-queued", "queued"))
        loop.close()
        assertEquals(listOf("first", "queued"), finished)
        assertEquals(listOf("first", "queued"), revoked)
        assertNull(loop.userId)
    }

    @Test fun should_require_saved_coach_reply_after_real_action_report() {
        val tracker = CoachRequestTracker()
        tracker.observe("user-report", null, null)
        tracker.expectMutationReply("user-report", "action_report", snapshot("real_report", "report-1"))
        tracker.toolSuccess("user-report", null)
        tracker.finish(tracker.ownerForUser("user-report"), snapshot("real_report", "report-1"))
        assertEquals("session-1", tracker.state.value!!.sessionId)
        assertEquals("reply_not_saved", tracker.state.value!!.reason)
        assertTrue(tracker.state.value!!.canRetry)
    }

    @Test fun should_finish_setup_before_a_persisted_user_id_exists() {
        val tracker = CoachRequestTracker()
        tracker.begin("session-1", snapshot("setup", null))
        tracker.finish(tracker.ownerForUser(null), snapshot("setup", null), error = "没有可用模型")
        assertFalse(tracker.state.value!!.isRunning)
        assertEquals("没有可用模型", tracker.state.value!!.error)
    }

    @Test fun should_keep_same_user_retry_running_after_old_loop_finishes() {
        val tracker = CoachRequestTracker()
        tracker.begin("session-1", snapshot())
        tracker.bindUser("same-user")
        val oldLoop = CoachRequestLoop("same-user",
            { tracker.finish(it, snapshot(), cancelled = true) }, {}, tracker.currentOwner())
        tracker.finish(tracker.ownerForUser("same-user"), snapshot(), cancelled = true)
        tracker.begin("session-1", snapshot())
        tracker.bindUser("same-user")
        val retryId = tracker.state.value!!.requestId
        oldLoop.close()
        assertTrue(tracker.state.value!!.isRunning)
        assertEquals(retryId, tracker.state.value!!.requestId)
    }

    @Test fun should_keep_new_user_request_and_permission_after_cancelled_old_loop_closes() {
        val tracker = CoachRequestTracker()
        val routing = CoachTurnRouting()
        tracker.begin("session-1", snapshot())
        tracker.bindUser("old-user")
        val oldOwner = tracker.currentOwner()!!
        val oldAuthorization = routing.authorize("old-user", "main")!!
        val loop = CoachRequestLoop("old-user",
            { tracker.finish(it, snapshot(), cancelled = true) }, routing::revoke,
            oldOwner, oldAuthorization)
        tracker.finish(oldOwner, snapshot(), cancelled = true)
        routing.revoke(oldAuthorization)
        tracker.begin("session-1", snapshot())
        tracker.bindUser("new-user")
        val newOwner = tracker.currentOwner()!!
        routing.authorize("new-user", "main")
        loop.close()
        assertTrue(tracker.state.value!!.isRunning)
        assertEquals(newOwner, tracker.currentOwner())
        assertNull(routing.denialReason("new-user", "main", true, false, false, false))
        assertEquals("foreground_required", routing.denialReason("old-user", "main", true, false, false, false))
    }

    @Test fun should_reject_old_setup_binding_and_cleanup_before_user_persistence() {
        val tracker = CoachRequestTracker()
        tracker.begin("session-1", snapshot("setup", null))
        val oldOwner = tracker.currentOwner()!!
        tracker.finish(oldOwner, snapshot(), cancelled = true)
        tracker.begin("session-1", snapshot("setup", null))
        val newOwner = tracker.currentOwner()!!
        assertFalse(tracker.bindUser("late-old-user", oldOwner.requestId))
        tracker.finish(oldOwner, snapshot(), cancelled = true)
        assertTrue(tracker.state.value!!.isRunning)
        assertEquals(newOwner, tracker.currentOwner())
        assertTrue(tracker.bindUser("new-user", newOwner.requestId))
        tracker.finish(newOwner, snapshot(), cancelled = true)
        assertTrue(tracker.state.value!!.isRunning)
        assertEquals("new-user", tracker.currentUserId())
    }

    @Test fun should_ignore_cleanup_with_right_request_id_but_wrong_user() {
        val tracker = CoachRequestTracker()
        tracker.begin("session-1", snapshot())
        tracker.bindUser("new-user")
        val owner = tracker.currentOwner()!!
        tracker.finish(owner.copy(userId = "old-user"), snapshot(), cancelled = true)
        assertTrue(tracker.state.value!!.isRunning)
        tracker.finish(owner, snapshot("probe", null))
        assertFalse(tracker.state.value!!.isRunning)
    }

    @Test fun should_capture_first_natural_request_without_rebinding_to_a_same_user_retry() {
        val tracker = CoachRequestTracker()
        val loop = CoachRequestLoop("same-user", { tracker.finish(it, snapshot()) }, {})
        tracker.observe("same-user", "session-1", snapshot())
        val oldOwner = tracker.currentOwner()!!
        loop.bindRequest(oldOwner)
        tracker.finish(oldOwner, snapshot(), cancelled = true)
        assertNull(tracker.ownerForUser("same-user"))
        tracker.observe("same-user", "session-1", snapshot())
        val newOwner = tracker.currentOwner()!!
        loop.bindRequest(newOwner)
        loop.close()
        assertTrue(tracker.state.value!!.isRunning)
        assertEquals(newOwner, tracker.currentOwner())
    }

    @Test fun should_show_protocol_message_and_preserve_failure_reason() {
        val tracker = CoachRequestTracker()
        tracker.observe("user-1", null, null)
        tracker.toolFailure("user-1", "tool_failed",
            """{"success":false,"reason":"invalid_revision","revision":0,"message":"expectedRevision must be an integer"}""")
        tracker.finish(tracker.currentOwner(), null)
        assertEquals("expectedRevision must be an integer", tracker.state.value!!.error)
        assertEquals("invalid_revision", tracker.state.value!!.reason)
    }
}
