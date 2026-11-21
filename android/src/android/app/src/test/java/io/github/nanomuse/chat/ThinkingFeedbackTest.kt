package io.github.nanomuse.chat

import com.openminis.app.ui.chat.AssistantBlock
import com.openminis.app.ui.chat.ChatMessage
import com.openminis.app.ui.chat.FlatChatItem
import com.openminis.app.ui.chat.ToolBlockStatus
import com.openminis.app.ui.chat.buildFlatChatItems
import org.junit.Assert.assertEquals
import org.junit.Test

/** 使用实际聊天行构建器回放一轮模型请求、工具调用、下一轮等待和结束。 */
class ThinkingFeedbackTest {
    @Test
    fun should_showOnlyOneIndicator_when_turnChangesPhase() {
        val pending = ChatMessage("turn", "assistant", "", isStreaming = true, isAwaitingModelResponse = true)
        val reasoning = AssistantBlock("r", "thinking", content = "reason")
        val tool = AssistantBlock("tool", "tool_use", toolStatus = ToolBlockStatus.RUNNING)
        val answer = AssistantBlock("a", "text", content = "answer")
        val samples = listOf(
            pending to (1 to 0),
            pending.copy(toolBlocks = listOf(reasoning), isAwaitingModelResponse = false) to (0 to 1),
            pending.copy(toolBlocks = listOf(reasoning, tool)) to (0 to 0),
            pending.copy(toolBlocks = listOf(tool, reasoning), isAwaitingModelResponse = false) to (0 to 0),
            pending.copy(toolBlocks = listOf(reasoning)) to (1 to 0),
            pending.copy(toolBlocks = listOf(reasoning, tool.copy(toolStatus = ToolBlockStatus.SUCCESS))) to (1 to 0),
            pending.copy(toolBlocks = listOf(reasoning, answer), isAwaitingModelResponse = false) to (0 to 0),
            pending.copy(error = "failed") to (0 to 0),
            pending.copy(isStreaming = false) to (0 to 0),
        )
        for ((message, expected) in samples) {
            val rows = buildFlatChatItems(listOf(message), showSteps = false, foldSteps = true)
            assertEquals(expected, rows.count { it is FlatChatItem.AssistantTyping } to
                rows.filterIsInstance<FlatChatItem.AssistantSteps>().count { it.isThinking })
            val expanded = buildFlatChatItems(listOf(message), showSteps = true, foldSteps = false)
            assertEquals(expected, expanded.count { it is FlatChatItem.AssistantTyping } to
                expanded.filterIsInstance<FlatChatItem.AssistantThinking>().count { it.isLastBlockOverall && it.isReceivingModelResponse })
        }
    }
}
