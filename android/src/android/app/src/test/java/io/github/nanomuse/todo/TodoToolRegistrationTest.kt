package io.github.nanomuse.todo

import com.openminis.app.tools.AgentTools
import org.junit.Assert.*
import org.junit.Test

/** 个人待办的工具开关不能随教练入口默认开放。 */
class TodoToolRegistrationTest {
    @Test fun should_hideTodo_when_callerHasNotEnabledIt() {
        assertFalse(AgentTools.makeAgentTools().any { it.name.startsWith("todo_") })
        assertFalse(AgentTools.makeAgentTools(coachEnabled = true).any { it.name.startsWith("todo_") })
    }

    @Test fun should_exposeOnlyTodo_when_mainHostEnablesTodoWithoutCoach() {
        val names = AgentTools.makeAgentTools(todoEnabled = true).map { it.name }.toSet()
        assertTrue(TodoAgentBridge.QUERY in names)
        assertTrue(TodoAgentBridge.COMMAND in names)
        assertFalse(names.any { it.startsWith("coach_") })
    }
}
