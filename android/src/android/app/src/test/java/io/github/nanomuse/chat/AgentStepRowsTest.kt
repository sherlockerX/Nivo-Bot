package io.github.nanomuse.chat

import com.openminis.app.ui.chat.AssistantBlock
import com.openminis.app.ui.chat.FlatChatItem
import org.junit.Assert.*
import org.junit.Test

/** 折叠投影保持标题、回复和工具身份，正文可独立懒加载。 */
class AgentStepRowsTest {
    private val thought = AssistantBlock("thought", "thinking", "过程".repeat(3000))
    private val tool = AssistantBlock("tool", "tool_use", toolName = "shell_execute")
    private val steps = FlatChatItem.AssistantSteps("answer", listOf(thought, tool), false)

    @Test fun should_keepOriginalRows_when_allCollapsed() {
        val rows = listOf(steps, FlatChatItem.AssistantHeader("next"))
        assertSame(rows, expandAgentStepRows(rows, emptySet()))
    }

    @Test fun should_separateBodyFromFixedHeader_when_expanding() {
        val reply = FlatChatItem.AssistantHeader("reply")
        val rows = expandAgentStepRows(listOf(steps, reply), setOf("answer"))
        assertSame(steps, rows.first())
        assertSame(reply, rows.last())
        val parts = rows.filterIsInstance<FlatChatItem.AssistantStepPart>()
        assertEquals(thought.content, parts.filter { it.block.kind == "thinking" }.joinToString("") { it.text })
        assertTrue(parts.all { it.text.length <= MAX_STEP_TEXT_CHARS })
        assertSame(tool, parts.last().block)
        assertEquals(listOf(tool), parts.last().tools)
    }

    @Test fun should_expandOnlyChosenMessage_when_multipleFoldsExist() {
        val other = steps.copy(messageId = "other")
        val rows = expandAgentStepRows(listOf(steps, other), setOf("answer"))
        assertTrue(rows.filterIsInstance<FlatChatItem.AssistantStepPart>().all { it.messageId == "answer" })
        assertEquals(2, rows.count { it is FlatChatItem.AssistantSteps })
    }

    @Test fun should_preserveKeysAndStatus_when_streamAddsAProcessBlock() {
        val before = expandAgentStepRows(listOf(steps), setOf("answer"))
        val streaming = steps.copy(blocks = steps.blocks + tool.copy(id = "new"), isStreaming = true)
        val after = expandAgentStepRows(listOf(streaming), setOf("answer"))
        assertEquals(before.map { it.key }, after.take(before.size).map { it.key })
        assertTrue(after.filterIsInstance<FlatChatItem.AssistantStepPart>().all { it.isStreaming })
    }

    @Test fun should_keepKeysUnique_when_sourceHasDuplicateBlockIds() {
        val duplicate = steps.copy(blocks = listOf(tool, tool.copy(toolName = "other")))
        val rows = expandAgentStepRows(listOf(duplicate), setOf("answer"))
        assertEquals(rows.size, rows.map { it.key }.toSet().size)
    }

    @Test fun should_removeAllBodyRows_when_foldIsCollapsedAgain() {
        val rows = listOf(steps)
        expandAgentStepRows(rows, setOf("answer"))
        assertEquals(listOf(steps), expandAgentStepRows(rows, emptySet()))
    }

    @Test fun should_reuseHistoricalParts_when_anotherMessageStreams() {
        val cache = AgentStepRowsCache()
        val live = steps.copy(messageId = "live", isStreaming = true)
        val expanded = setOf("answer", "live")
        val before = expandAgentStepRows(listOf(steps, live), expanded, cache)
        val after = expandAgentStepRows(listOf(steps, live.copy(blocks = live.blocks + tool.copy(id = "new"))), expanded, cache)
        val historical = before.filterIsInstance<FlatChatItem.AssistantStepPart>().filter { it.messageId == "answer" }
        val reused = after.filterIsInstance<FlatChatItem.AssistantStepPart>().filter { it.messageId == "answer" }
        historical.indices.forEach { index -> assertSame(historical[index], reused[index]) }
    }

    @Test fun should_releaseCachedParts_when_collapsedOrRemovedFromWindow() {
        val cache = AgentStepRowsCache()
        val before = expandAgentStepRows(listOf(steps), setOf("answer"), cache)
        expandAgentStepRows(emptyList(), setOf("answer"), cache)
        val afterRemoval = expandAgentStepRows(listOf(steps), setOf("answer"), cache)
        assertNotSame(before[1], afterRemoval[1])
        expandAgentStepRows(listOf(steps), emptySet(), cache)
        val afterCollapse = expandAgentStepRows(listOf(steps), setOf("answer"), cache)
        assertNotSame(afterRemoval[1], afterCollapse[1])
    }
}
