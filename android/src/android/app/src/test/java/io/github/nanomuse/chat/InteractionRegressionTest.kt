package io.github.nanomuse.chat

import com.openminis.app.ui.chat.*
import org.junit.Assert.*
import org.junit.Test

/** 对轮次边界、过程折叠和最终正文判定做回归。 */
class InteractionRegressionTest {
    @Test
    fun `early failure cannot target a previous answer`() {
        val rows = listOf(message("u0", "user"), message("a0", "assistant"), message("u1", "user"))
        assertEquals(-1, turnErrorTarget(rows))
        assertEquals(3, turnErrorTarget(rows + message("a1", "assistant")))
    }

    @Test
    fun `thinking tools and process text share one fold while answer and error remain visible`() {
        val answer = message("a", "assistant").copy(error = "failure", toolBlocks = listOf(
            AssistantBlock(id = "thought", kind = "thinking", content = "reasoning"),
            AssistantBlock(id = "before", kind = "text", content = "checking"),
            AssistantBlock(id = "tool", kind = "tool_use", toolName = "search"),
            AssistantBlock(id = "result", kind = "text", content = "final answer"),
        ))
        val rows = buildFlatChatItems(listOf(message("u", "user"), answer), showSteps = false, foldSteps = true)
        assertEquals(listOf("thought", "before", "tool"), rows.filterIsInstance<FlatChatItem.AssistantSteps>().single().blocks.map { it.id })
        assertEquals("final answer", rows.filterIsInstance<FlatChatItem.AssistantMarkdownBlock>().single().rawText)
        assertTrue(rows.last { it is FlatChatItem.AssistantError } is FlatChatItem.AssistantError)
        assertTrue(rows.none { it is FlatChatItem.AssistantToolUse || it is FlatChatItem.AssistantThinking })
    }

    @Test
    fun `steps only replies remain accessible when appearance hides expanded steps`() {
        val answer = message("a", "assistant").copy(toolBlocks = listOf(
            AssistantBlock(id = "tool", kind = "tool_use", toolName = "shell")))
        assertEquals(1, buildFlatChatItems(listOf(answer), showSteps = false, foldSteps = true).filterIsInstance<FlatChatItem.AssistantSteps>().size)
    }

    @Test
    fun `incremental and complete folding produce the same rows`() {
        val messages = listOf(message("u0", "user"), message("a0", "assistant"), message("u1", "user"),
            message("a1", "assistant").copy(toolBlocks = listOf(AssistantBlock(id = "t", kind = "thinking", content = "thinking"))))
        val prefix = buildFlatChatItems(messages.take(2), foldSteps = true)
        val suffix = buildFlatChatItems(messages, fromIndex = 2, seedKeys = prefix.map { it.key }.toSet(), foldSteps = true)
        assertEquals(buildFlatChatItems(messages, foldSteps = true), prefix + suffix)
    }

    @Test
    fun `only normal nonempty terminal answer with no pending tools can be spoken`() {
        assertTrue(isFinalReplyReady("stop", "answer", false))
        assertTrue(isFinalReplyReady("end_turn", "answer", false))
        listOf(null, "length", "max_tokens", "tool_use", "cancelled").forEach {
            assertFalse(isFinalReplyReady(it, "process text", false))
        }
        assertFalse(isFinalReplyReady("stop", "", false))
        assertFalse(isFinalReplyReady("stop", "process text", true))
    }

    private fun message(id: String, role: String) = ChatMessage(id = id, role = role, content = "")
}
