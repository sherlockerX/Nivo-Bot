package io.github.nanomuse.chat

internal const val MAX_STEP_TEXT_CHARS = 1200

/** 将过程长文本切成有界的列表行，避免单行测量整段思考。 */
internal fun stepTextChunks(content: String): List<String> {
    if (content.isBlank()) return emptyList()
    return buildList {
        var start = 0
        while (start < content.length) {
            val end = chunkEnd(content, start)
            add(content.substring(start, end))
            start = end
        }
    }
}

private fun chunkEnd(content: String, start: Int): Int {
    var end = (start + MAX_STEP_TEXT_CHARS).coerceAtMost(content.length)
    if (end == content.length) return end
    for (position in end - 1 downTo start + MAX_STEP_TEXT_CHARS / 2) {
        if (content[position] == '\n') return position + 1
    }
    if (content[end - 1].isHighSurrogate() && content[end].isLowSurrogate()) end--
    return end
}
