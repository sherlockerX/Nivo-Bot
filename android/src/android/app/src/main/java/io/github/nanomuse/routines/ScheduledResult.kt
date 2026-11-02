package io.github.nanomuse.routines

import org.json.JSONArray
import java.security.MessageDigest

/** 一次运行给用户看的结果；过程（思考、工具调用、上报确认）只进日志与会话。 */
data class ScheduledResult(val text: String?, val source: String) {
    val bytes: Int get() = text?.toByteArray(Charsets.UTF_8)?.size ?: 0
    val hash: String? get() = text?.let { value ->
        "sha256:" + MessageDigest.getInstance("SHA-256").digest(value.toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it.toInt() and 255) }
    }

    companion object {
        /** 结果正文上限，超出部分只在会话与日志里。 */
        const val MAX_CHARS = 4000
        const val NO_OUTPUT = "NO_OUTPUT"

        /** 不建会话的脚本运行使用按任务固定的执行身份，不写入聊天列表。 */
        private const val SESSIONLESS_PREFIX = "nm-task-run-"
        fun sessionless(taskId: String) = SESSIONLESS_PREFIX + taskId
        fun isSessionless(id: String?) = id?.startsWith(SESSIONLESS_PREFIX) == true

        /** 脚本结果是去掉首尾空行后的 stdout；全空白视为没有结果。 */
        fun script(stdout: String?): ScheduledResult {
            val text = stdout.orEmpty().replace("\r\n", "\n").lines().map { it.trimEnd() }
                .dropWhile { it.isBlank() }.dropLastWhile { it.isBlank() }.joinToString("\n")
            return if (text.isBlank()) ScheduledResult(null, "none") else ScheduledResult(text, "script_stdout")
        }

        /** 提示词结果：自报优先，其次是最后一次工具调用之后的回答正文。 */
        fun prompt(reported: String?, partsJson: String?): ScheduledResult {
            reported?.let(::sanitize)?.takeIf { it.isNotBlank() && it != NO_OUTPUT }?.let { return ScheduledResult(it, "self_report") }
            val answer = partsJson?.let(::answerText)?.let(::sanitize)
            return if (answer.isNullOrBlank() || answer == NO_OUTPUT) ScheduledResult(null, "none")
            else ScheduledResult(answer, "final_message")
        }

        /** 消息里最后一个 toolUse 之后的文本块；没有工具调用时就是全部文本。 */
        private fun answerText(partsJson: String): String? = runCatching {
            val parts = JSONArray(partsJson)
            val all = (0 until parts.length()).mapNotNull { parts.optJSONObject(it) }
            val lastTool = all.indexOfLast { it.optString("type") == "toolUse" }
            all.drop(lastTool + 1).filter { it.optString("type") == "text" }
                .map { it.optString("value").trim() }.filter { it.isNotEmpty() }.joinToString("\n\n")
        }.getOrNull()

        // 兜底：模型不守输出约定时漏出的过程说明。
        private val META_LINES = listOf(
            Regex("""^已上报(成功|失败).*$"""),
            Regex("""^任务(本身)?(已经)?(跑完|完成|执行完成|执行完毕).*$"""),
            Regex("""^\(?（?run_id[:：]?\s*\S+[)）]?$""", RegexOption.IGNORE_CASE),
            Regex("""^（?这是预期行为.*$"""),
            Regex("""^(reported|report sent|the task (has )?(finished|completed)).*$""", RegexOption.IGNORE_CASE),
        )

        private fun sanitize(text: String): String = text.lines()
            .filterNot { line -> META_LINES.any { it.matches(line.trim()) } }
            .joinToString("\n").trim()
    }
}
