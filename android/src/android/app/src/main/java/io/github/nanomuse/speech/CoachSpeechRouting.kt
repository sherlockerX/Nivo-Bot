package io.github.nanomuse.speech

/** 单次播放器的语音来源约束，普通聊天继续跟随用户的全局选择。 */
enum class SpeechOutputPolicy {
    FOLLOW_SELECTION,
    SYSTEM_ONLY;

    /** 只有允许服务商时才执行查询，系统朗读不访问服务商或凭据。 */
    fun <T> resolveProvider(resolve: () -> T?): T? =
        if (this == SYSTEM_ONLY) null else resolve()
}

/** 仅由结构化教练工具名判断历史消息，不从正文猜测教练身份。 */
internal fun isCoachToolName(toolName: String): Boolean =
    toolName == "coach" || toolName.startsWith("coach_")

/** 保存当前聊天页面已知的教练消息策略，供关闭自动朗读后的手动重读使用。 */
internal class CoachSpeechRouting {
    private val systemOnlyMessageIds = mutableSetOf<String>()

    /** 记录已确认的教练消息，普通消息不会解除已有的系统语音约束。 */
    fun remember(messageId: String, systemOnly: Boolean) {
        if (systemOnly) systemOnlyMessageIds += messageId.substringBefore('#')
    }

    /** 将界面拆分出的正文块映射回原始消息的语音策略。 */
    fun policyFor(messageId: String, systemOnly: Boolean = false): SpeechOutputPolicy {
        remember(messageId, systemOnly)
        return if (messageId.substringBefore('#') in systemOnlyMessageIds) {
            SpeechOutputPolicy.SYSTEM_ONLY
        } else {
            SpeechOutputPolicy.FOLLOW_SELECTION
        }
    }

    /** 连续选区包含教练消息时整体使用系统语音，来源未知时也不交给服务商。 */
    fun policyForSelection(messageIds: List<String>, orderedMessageIds: List<String>): SpeechOutputPolicy {
        val selected = messageIds.map { it.substringBefore('#') }.distinct()
        val ordered = orderedMessageIds.map { it.substringBefore('#') }
        if (selected.isEmpty() || selected.any { it !in ordered }) return SpeechOutputPolicy.SYSTEM_ONLY
        val indexes = selected.map { ordered.indexOf(it) }
        val covered = ordered.subList(indexes.min(), indexes.max() + 1)
        return if (covered.any { it in systemOnlyMessageIds }) {
            SpeechOutputPolicy.SYSTEM_ONLY
        } else {
            SpeechOutputPolicy.FOLLOW_SELECTION
        }
    }

    /** 页面销毁时释放消息索引。 */
    fun clear() = systemOnlyMessageIds.clear()
}
