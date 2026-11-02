package io.github.nanomuse.chat

import com.openminis.app.ui.chat.ChatMessage

/** 错误只关联本轮用户消息之后的回复，没有回复时由调用者创建占位。 */
internal fun turnErrorTarget(messages: List<ChatMessage>): Int {
    val userIndex = messages.indexOfLast { it.role == "user" }
    val assistantIndex = messages.indexOfLast { it.role == "assistant" }
    return assistantIndex.takeIf { it > userIndex } ?: -1
}
