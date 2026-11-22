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

/** 面板里一段思考的折叠状态：收起时只显示开头几行；展开后在最后一个片段下提供收起。 */
internal data class StepFold(val isCollapsed: Boolean, val hasMore: Boolean, val showCollapse: Boolean)

/** 一段思考在面板中的身份：同一块在一次回复里可能出现多次。 */
internal fun stepFoldKey(part: FlatChatItem.AssistantStepPart): String = "${part.block.id}:${part.occurrence}"

/** 展开后至少这么长的思考才提供"收起"，短思考没有折叠入口。 */
internal const val STEP_FOLD_MIN_CHARS = 120

/**
 * 按折叠状态挑出面板要显示的片段。思考收起时只保留第一个片段，由界面限制为几行；
 * 展开时保留全部片段。工具和说明文字不折叠，折叠信息为空。
 */
internal fun visibleStepParts(
    parts: List<FlatChatItem.AssistantStepPart>, isOpen: (String) -> Boolean,
): List<Pair<FlatChatItem.AssistantStepPart, StepFold?>> {
    val thinking = parts.filter { it.block.kind == "thinking" }.groupBy(::stepFoldKey)
    return parts.mapNotNull { part ->
        if (part.block.kind != "thinking") return@mapNotNull part to null
        val key = stepFoldKey(part)
        val group = thinking.getValue(key)
        val isLastPart = part.partIndex == group.maxOf { it.partIndex }
        val isLong = group.size > 1 || group.sumOf { it.text.length } > STEP_FOLD_MIN_CHARS
        when {
            isOpen(key) -> part to StepFold(isCollapsed = false, hasMore = false, showCollapse = isLastPart && isLong)
            part.partIndex == 0 -> part to StepFold(isCollapsed = true, hasMore = group.size > 1, showCollapse = false)
            else -> null
        }
    }
}

