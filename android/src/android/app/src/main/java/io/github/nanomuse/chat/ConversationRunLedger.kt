package io.github.nanomuse.chat

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

/** 每个正在执行的会话使用独立的单调时钟和简短请求文本。 */
data class ConversationRun(val sessionId: String, val startedAt: Long, val brief: String)

/** 管理进程内任务计时和真正未读的完成状态。 */
class ConversationRunLedger {
    private val active = MutableStateFlow<Map<String, ConversationRun>>(emptyMap())
    val runs: StateFlow<Map<String, ConversationRun>> = active
    private val completed = MutableStateFlow<Map<String, Boolean>>(emptyMap())
    val outcomes: StateFlow<Map<String, Boolean>> = completed
    private val viewing = mutableSetOf<String>()

    /** 标记当前可见会话。 */
    @Synchronized fun setViewing(id: String, visible: Boolean) {
        if (visible) {
            viewing.add(id)
            completed.value = completed.value - id
        } else viewing.remove(id)
    }
    /** 开始任务，重复登记不重置已有计时。 */
    @Synchronized fun start(id: String, now: Long, brief: String) {
        if (id in active.value) return
        completed.value = completed.value - id
        active.value = active.value + (id to ConversationRun(id, now, brief.replace(Regex("\\s+"), " ").trim()))
    }
    /** 完成任务，只为尚未查看的结果保留状态点。 */
    @Synchronized fun finish(id: String, isError: Boolean) {
        if (id !in active.value) return
        active.value = active.value - id
        if (id in viewing) return
        completed.value = (completed.value - id + (id to !isError)).entries.toList().takeLast(256).associate { it.toPair() }
    }
    /** 按开始时间输出每个任务的摘要和用时。 */
    fun lines(now: Long, fallback: String): List<String> = active.value.values.sortedBy { it.startedAt }.map { run ->
        val source = run.brief.ifBlank { fallback }
        val characters = source.codePointCount(0, source.length)
        val brief = if (characters > 18) source.substring(0, source.offsetByCodePoints(0, 18)) + "…" else source
        "$brief · ${elapsed(now - run.startedAt)}"
    }

    companion object {
        /** 单调时钟差值转为可读的用时，不受系统校时影响。 */
        fun elapsed(duration: Long): String {
            val seconds = duration.coerceAtLeast(0) / 1000
            return if (seconds < 3600) String.format(java.util.Locale.ROOT, "%02d:%02d", seconds / 60, seconds % 60)
            else String.format(java.util.Locale.ROOT, "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
        }
    }
}
