package io.github.nanomuse.routines

import com.openminis.app.data.repository.ChatRepository
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay
import org.json.JSONArray
import org.json.JSONObject

/** 落库重试使用同一消息身份，避免提交后异常造成重复消息。 */
object ScheduledOutputWriter {
    /** 初次尝试加三次重试，取消不重试、不吞掉。 */
    suspend fun <Result> retryWrite(operation: suspend () -> Result): Result {
        val delays = listOf(200L, 1000L, 3000L)
        repeat(4) { attempt ->
            try { return operation() }
            catch (cancelled: CancellationException) { throw cancelled }
            catch (failure: Exception) {
                if (attempt == 3) throw IllegalStateException("MESSAGE_WRITE_FAILED", failure)
                delay(delays[attempt])
            }
        }
        error("MESSAGE_WRITE_FAILED")
    }

    /**
     * Mosaic: 脚本结果前的任务唤醒行。它是用户一侧的一行，聊天里画成“例程 · 名称 · 时间”的小字，
     * 每次运行的结果因此各成一条；正文是这次运行的命令，之后在这个对话里聊天时模型知道上面是什么。
     */
    suspend fun wake(repository: ChatRepository, sessionId: String, scope: ScheduledRunScope, label: String, command: String) {
        val id = "task-wake:${scope.runId}"
        val parts = JSONArray().put(JSONObject().put("type", "text").put("value", command)).toString()
        retryWrite { repository.dao.findMessage(id) ?: repository.appendMessage(sessionId, "user", parts, messageId = id) }
        io.github.nanomuse.chat.RoutineWakes.mark(id, label)
    }

    /** 保存可见消息并回读实际持久文本，计量不使用内存中的推测值。 */
    suspend fun write(repository: ChatRepository, sessionId: String, scope: ScheduledRunScope,
        role: String, text: String): Long = retryWrite {
        val parts = JSONArray().put(JSONObject().put("type", "text").put("value", text)).toString()
        val message = repository.appendMessage(sessionId, role, parts, messageId = "task-run:${scope.runId}")
        val saved = repository.dao.findMessage(message.id) ?: error("MESSAGE_WRITE_FAILED")
        val array = JSONArray(saved.partsJson)
        val actual = (0 until array.length()).mapNotNull { array.optJSONObject(it) }
            .filter { it.optString("type") == "text" }.joinToString("") { it.optString("value") }
        check(actual == text) { "MESSAGE_WRITE_FAILED" }
        actual.toByteArray(Charsets.UTF_8).size.toLong()
    }
}
