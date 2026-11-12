package io.github.nanomuse.chat

import android.content.Context
import com.openminis.app.data.db.MessageEntity
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.util.concurrent.Executors

/** 根据已持久化消息保存可核实事件，不用模型补写虚构的历史经历。 */
object DailyEventJournal {
    private val worker = Executors.newSingleThreadExecutor()
    private var directory: File? = null
    private val seen = linkedMapOf<LocalDate, MutableSet<String>>()
    private var seenOperation: io.github.nanomuse.account.AccountOperation? = null
    private var isGlobalMemoryEnabled: () -> Boolean = { false }

    /** 事件与人工记忆分目录保存，索引明确区分无事件和缺日志。 */
    fun init(context: Context) {
        val application = context.applicationContext
        isGlobalMemoryEnabled = { com.openminis.app.data.MemoryGlobalPrefs.isGlobalEnabled(application) }
        val memory = File(context.filesDir, "minis-global/memory")
        val operation = io.github.nanomuse.account.AccountData.captureOperation()
        worker.execute {
            directory = File(memory, "events")
            runCatching { operation.files { directory?.mkdirs(); updateIndex(memory) } }
        }
    }

    /** 只为开启记忆的会话记录文本及工具结果摘要，不读取图片和附件。 */
    fun record(message: MessageEntity, isMemoryEnabled: Boolean,
        operation: io.github.nanomuse.account.AccountOperation = io.github.nanomuse.account.AccountData.captureOperation()) {
        if (!isMemoryEnabled || !isGlobalMemoryEnabled()) return
        worker.execute {
            runCatching {
                operation.files {
                    val base = directory ?: return@files
                    if (seenOperation?.isCurrent() != true) { seen.clear(); seenOperation = operation }
                    base.mkdirs() // nanoMuse: 新账号没有旧目录时按当前代次建立事件目录。
                    val parts = JSONArray(message.partsJson)
                    val text = (0 until parts.length()).mapNotNull { parts.optJSONObject(it) }
                        .filter { it.optString("type") == "text" }.joinToString(" ") { it.optString("value") }.take(160)
                    val results = (0 until parts.length()).mapNotNull { parts.optJSONObject(it) }
                        .filter { it.optString("type") == "toolResult" }.mapNotNull { it.optJSONObject("value") }
                    val event = JSONObject().put("message_id", message.id).put("session_id", message.sessionId)
                        .put("created_at_ms", message.createdAt).put("role", message.role).put("text_excerpt", text)
                        .put("tool_success", results.count { it.optBoolean("success") }).put("tool_failure", results.count { !it.optBoolean("success") })
                    val date = Instant.ofEpochMilli(message.createdAt).atZone(ZoneId.systemDefault()).toLocalDate()
                    val file = File(base, "$date.jsonl")
                    val ids = seen.getOrPut(date) {
                        if (!file.exists()) mutableSetOf() else file.useLines { lines -> lines.mapNotNull { runCatching { JSONObject(it).getString("message_id") }.getOrNull() }.toMutableSet() }
                    }
                    if (ids.add(message.id)) file.appendText("$event\n")
                    if (seen.size > 8) seen.remove(seen.keys.first())
                    updateIndex(base.parentFile!!)
                }
            }
        }
    }

    private fun updateIndex(memory: File) {
        val today = LocalDate.now()
        val text = buildString {
            append("# 可核实事件索引\n事件来自已保存且开启记忆的对话，不等于模型已确认任务成功。未记录不表示数据丢失，不补造历史。\n")
            repeat(7) { offset ->
                val day = today.minusDays(offset.toLong())
                val source = File(memory, "events/$day.jsonl")
                val manual = File(memory, "$day.md")
                append("- $day: ${if (source.isFile) "事件文件events/$day.jsonl" else "无可核实事件文件"}；${if (manual.isFile) "有每日日志" else "无人工或模型每日日志"}\n")
            }
        }
        File(memory, "EVENTS.md").writeText(text)
    }
}
