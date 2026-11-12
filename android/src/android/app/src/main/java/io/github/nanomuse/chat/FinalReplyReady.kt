package io.github.nanomuse.chat

/** 只有正常结束且没有待执行工具的模型正文才能进入自动朗读。 */
data class FinalReplyReady(
    val messageId: String,
    val generationId: String,
    val text: String,
    val systemOnly: Boolean = false,
)

/** 过滤中断、截断、空回复和执行中的工具，避免朗读过程说明。 */
internal fun isFinalReplyReady(reason: String?, text: String, hasPendingTools: Boolean): Boolean =
    (reason == "stop" || reason == "end_turn") && text.isNotBlank() && !hasPendingTools
