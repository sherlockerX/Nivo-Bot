package io.github.nanomuse.chat

import com.openminis.app.ui.chat.FlatChatItem

/** 按不可变源行身份复用历史片段，不随其他消息的流式更新重复切片。 */
internal class AgentStepRowsCache {
    private data class Entry(val source: FlatChatItem.AssistantSteps, val parts: List<FlatChatItem.AssistantStepPart>)
    private val entries = mutableMapOf<String, Entry>()

    /** 只有源行替换时才重建该消息的过程片段。 */
    fun partsFor(row: FlatChatItem.AssistantSteps): List<FlatChatItem.AssistantStepPart> {
        val previous = entries[row.key]
        if (previous?.source === row) return previous.parts
        return stepParts(row).also { entries[row.key] = Entry(row, it) }
    }

    /** 收起或移出加载窗口后释放片段，不无限持有历史正文。 */
    fun retain(keys: Set<String>) {
        entries.keys.retainAll(keys)
    }
}

/** 保留固定标题，仅为已展开的过程投影懒加载正文行。 */
internal fun expandAgentStepRows(
    rows: List<FlatChatItem>, expanded: Set<String>, cache: AgentStepRowsCache = AgentStepRowsCache(),
): List<FlatChatItem> {
    val retained = mutableSetOf<String>()
    if (expanded.isEmpty()) {
        cache.retain(retained)
        return rows
    }
    val projected = buildList {
        rows.forEach { row ->
            add(row)
            if (row is FlatChatItem.AssistantSteps && row.messageId in expanded) {
                retained.add(row.key)
                addAll(cache.partsFor(row))
            }
        }
    }
    cache.retain(retained)
    return projected
}

private fun stepParts(row: FlatChatItem.AssistantSteps): List<FlatChatItem.AssistantStepPart> {
    val tools = row.blocks.filter { it.kind == "tool_use" }
    val occurrences = mutableMapOf<String, Int>()
    return buildList {
        row.blocks.forEach { block ->
            val occurrence = occurrences.getOrDefault(block.id, 0)
            occurrences[block.id] = occurrence + 1
            val parts = if (block.kind == "tool_use") listOf("") else stepTextChunks(block.content)
            parts.forEachIndexed { index, text ->
                add(FlatChatItem.AssistantStepPart(row.messageId, block, occurrence, index, text, row.isStreaming, tools))
            }
        }
    }
}
