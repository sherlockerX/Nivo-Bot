package io.github.nanomuse.routines

import org.junit.Assert.*
import org.junit.Test

/** 不同会话不能绕过同一任务的独占，迟到收尾不得清除新运行。 */
class ScheduledTaskConcurrencyTest {
    @Test fun should_rejectSecondConversation_when_sameTaskAlreadyRuns() {
        val first = ScheduledRunScope("shared-task")
        val second = ScheduledRunScope("shared-task")
        assertTrue(ScheduledRunScopes.enter("first-chat", first))
        try {
            assertFalse(ScheduledRunScopes.enter("second-chat", second))
            assertTrue(ScheduledRunScopes.hasTask("shared-task"))
        } finally {
            ScheduledRunScopes.leave("first-chat", first)
            ScheduledRunScopes.leave("second-chat", second)
        }
    }

    @Test fun should_preserveLaterRun_when_oldCleanupRepeats() {
        val first = ScheduledRunScope("cleanup-task")
        val second = ScheduledRunScope("cleanup-task")
        assertTrue(ScheduledRunScopes.enter("cleanup-chat", first))
        ScheduledRunScopes.leave("cleanup-chat", first)
        assertTrue(ScheduledRunScopes.enter("cleanup-chat", second))
        try {
            ScheduledRunScopes.leave("cleanup-chat", first)
            assertTrue(ScheduledRunScopes.isActive("cleanup-chat"))
            assertTrue(ScheduledRunScopes.hasTask("cleanup-task"))
        } finally { ScheduledRunScopes.leave("cleanup-chat", second) }
    }

    @Test fun should_allowIndependentTasks_when_sessionsDiffer() {
        val first = ScheduledRunScope("independent-first")
        val second = ScheduledRunScope("independent-second")
        assertTrue(ScheduledRunScopes.enter("independent-chat-first", first))
        try {
            assertTrue(ScheduledRunScopes.enter("independent-chat-second", second))
        } finally {
            ScheduledRunScopes.leave("independent-chat-first", first)
            ScheduledRunScopes.leave("independent-chat-second", second)
        }
    }

    @Test fun should_leaveOtherTasksAvailable_when_sameSessionRejectsBinding() {
        val first = ScheduledRunScope("session-owner")
        val second = ScheduledRunScope("session-rejected")
        assertTrue(ScheduledRunScopes.enter("same-session", first))
        try {
            assertFalse(ScheduledRunScopes.enter("same-session", second))
            assertTrue(ScheduledRunScopes.enter("other-session", second))
        } finally {
            ScheduledRunScopes.leave("same-session", first)
            ScheduledRunScopes.leave("other-session", second)
        }
    }
}
