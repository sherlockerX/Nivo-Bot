package io.github.nanomuse.focus

import com.openminis.app.tools.AgentTools
import org.junit.Assert.*
import org.junit.Test

/** 专注只随主聊天待办权限开放，教练专题和默认工具集不携带控制能力。 */
class FocusToolRegistrationTest {
    @Test fun should_exposeOnlyQueries_when_OrdinaryChatHasPersonalRecordsReadAccess() {
        val names = AgentTools.makeAgentTools(personalRecordsRead = true).map { it.name }
        assertTrue(names.containsAll(listOf("focus_query", "todo_query", "personal_records_query")))
        assertFalse(names.contains("focus_command"))
        assertFalse(names.contains("todo_command"))
        assertFalse(names.any { it.startsWith("coach_") })
    }

    @Test fun should_registerQueriesOnce_when_MainChatHasBothPermissions() {
        val names = AgentTools.makeAgentTools(todoEnabled = true, personalRecordsRead = true).map { it.name }
        assertEquals(1, names.count { it == "focus_query" })
        assertEquals(1, names.count { it == "todo_query" })
        assertTrue(names.containsAll(listOf("focus_command", "todo_command")))
    }

    @Test fun should_requirePersonalTaskScope_forFocusTools() {
        assertFalse(AgentTools.makeAgentTools().any { it.name.startsWith("focus_") })
        assertFalse(AgentTools.makeAgentTools(coachEnabled=true).any { it.name.startsWith("focus_") })
        assertTrue(AgentTools.makeAgentTools(todoEnabled=true).map { it.name }.containsAll(listOf("focus_query","focus_command")))
        val command=FocusAgentBridge.definitions().single { it.name==FocusAgentBridge.COMMAND }
        assertFalse(command.parameters.containsKey("elapsedMs"))
    }
}
