package io.github.nanomuse.chat

import com.openminis.app.ui.chat.ChatMessage

/** 内容导航条目，身份来自持久化消息行，正文仅在当前内存中预览。 */
data class MessageAnchor(val id: String, val text: String, val role: String, val saved: Boolean)

/** 返回可跨重新加载定位的消息身份。 */
fun anchorIdentity(message: ChatMessage): String = message.sourceDbIds.firstOrNull() ?: message.id

/** 将数据库行身份解析为当前合并消息的位置。 */
fun findAnchorMessage(messages: List<ChatMessage>, id: String): Int = messages.indexOfFirst { it.id == id || id in it.sourceDbIds }

/** 按目录、书签或关键词筛选消息。 */
fun anchorEntries(messages: List<ChatMessage>, saved: Set<String>, query: String, savedOnly: Boolean): List<MessageAnchor> {
    val needle = query.trim()
    return messages.asSequence().filter { it.role in setOf("user", "assistant") && !it.isInternalBridge && !it.isQueued }
        .map { message ->
            val text = message.content.ifBlank { message.toolBlocks.filter { it.kind == "text" }.joinToString("\n") { it.content } }
            val marked = message.id in saved || message.sourceDbIds.any { it in saved }
            MessageAnchor(anchorIdentity(message), text, message.role, marked)
        }.filter { entry ->
            val selected = if (savedOnly) entry.saved else needle.isNotBlank() || entry.role == "user" || entry.saved
            selected && (needle.isBlank() || entry.text.contains(needle, ignoreCase = true))
        }.map { entry ->
            val match = if (needle.isBlank()) 0 else entry.text.indexOf(needle, ignoreCase = true).coerceAtLeast(0)
            val start = (match - 35).coerceAtLeast(0)
            val end = (start + 220).coerceAtMost(entry.text.length)
            val preview = entry.text.substring(start, end).replace(Regex("\\s+"), " ")
            entry.copy(text = (if (start > 0) "…" else "") + preview + (if (end < entry.text.length) "…" else ""))
        }.toList()
}
