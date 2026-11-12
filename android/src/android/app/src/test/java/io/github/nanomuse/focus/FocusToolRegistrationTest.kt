package io.github.nanomuse.focus

import com.openminis.app.tools.AgentTools
import org.junit.Assert.*
import org.junit.Test

/** 专注只随主聊天待办权限开放，教练专题和默认工具集不携带控制能力。 */
class FocusToolRegistrationTest {
    @Test fun should_requirePersonalTaskScope_forFocusTools() {
        assertFalse(AgentTools.makeAgentTools().any { it.name.startsWith("focus_") })
        assertFalse(AgentTools.makeAgentTools(coachEnabled=true).any { it.name.startsWith("focus_") })
        assertTrue(AgentTools.makeAgentTools(todoEnabled=true).map { it.name }.containsAll(listOf("focus_query","focus_command")))
        val command=FocusAgentBridge.definitions().single { it.name==FocusAgentBridge.COMMAND }
        assertFalse(command.parameters.containsKey("elapsedMs"))
    }
}
