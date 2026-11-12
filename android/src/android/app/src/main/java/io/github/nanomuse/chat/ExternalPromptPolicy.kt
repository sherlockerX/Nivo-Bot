package io.github.nanomuse.chat

/** nanoMuse: 首页卡片与外部预填共用的输入保护规则。 */
object ExternalPromptPolicy {
    /** nanoMuse: 任何未提交状态都应先交回用户处理，避免发送或覆盖原输入。 */
    fun shouldProtect(
        inputText: String,
        editingMessageId: String?,
        hasAttachments: Boolean,
        hasPastedTexts: Boolean,
    ): Boolean = inputText.isNotEmpty() || editingMessageId != null ||
        hasAttachments || hasPastedTexts
}
