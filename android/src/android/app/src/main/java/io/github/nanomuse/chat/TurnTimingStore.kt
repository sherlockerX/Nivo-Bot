package io.github.nanomuse.chat

import android.content.Context
import kotlinx.coroutines.flow.MutableStateFlow
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID
import java.util.concurrent.Executors

/** 本地轮次计时账本，不存储对话正文；进程中断后不假装任务仍在运行。 */
object TurnTimingStore {
    private val worker = Executors.newSingleThreadExecutor()
    private val records = MutableStateFlow<List<JSONObject>>(emptyList())
    val revision = MutableStateFlow(0L)
    private var preferences: android.content.SharedPreferences? = null
    private val firstSeen = java.util.concurrent.ConcurrentHashMap.newKeySet<String>()

    /** 在应用启动时恢复已完成记录，并将上次未完成的轮次标记为中断。 */
    fun init(context: Context) {
        val prefs = context.applicationContext.getSharedPreferences("nm_turn_timings", Context.MODE_PRIVATE)
        worker.execute {
            preferences = prefs
            val saved = runCatching { JSONArray(prefs.getString("records", "[]")) }.getOrDefault(JSONArray())
            val restored = (0 until saved.length()).mapNotNull { saved.optJSONObject(it) }
            restored.filter { it.optString("status") == "running" }.forEach { it.put("status", "aborted") }
            persist(restored)
        }
    }

    /** 登记真实任务开始时间，不使用界面进入时间。 */
    fun begin(sessionId: String, startedAtMs: Long, monotonicMs: Long) {
        firstSeen.remove(sessionId)
        worker.execute {
            if (records.value.any { it.optString("session_id") == sessionId && it.optString("status") == "running" }) return@execute
            persist(records.value + JSONObject().put("turn_id", UUID.randomUUID().toString())
                .put("session_id", sessionId).put("started_at_ms", startedAtMs)
                .put("monotonic_ms", monotonicMs).put("status", "running"))
        }
    }

    /** 记录实际结束时间和单调时钟耗时。 */
    fun finish(sessionId: String, finishedAtMs: Long, monotonicMs: Long, isError: Boolean) {
        worker.execute {
            val previous = records.value.lastOrNull { it.optString("session_id") == sessionId && it.optString("status") == "running" } ?: return@execute
            val current = JSONObject(previous.toString())
            current.put("finished_at_ms", finishedAtMs)
                .put("elapsed_ms", (monotonicMs - current.optLong("monotonic_ms")).coerceAtLeast(0))
                .put("status", if (isError) "error" else "completed")
            persist(records.value.map { if (it === previous) current else it })
        }
    }

    /** 首次可见输出时间只记一次；没有输出则保持空值。 */
    fun firstOutput(sessionId: String, atMs: Long) {
        if (!firstSeen.add(sessionId)) return
        worker.execute {
            val previous = records.value.lastOrNull { it.optString("session_id") == sessionId && it.optString("status") == "running" } ?: return@execute
            if (previous.has("first_output_at_ms")) return@execute
            val current = JSONObject(previous.toString()).put("first_output_at_ms", atMs)
            persist(records.value.map { if (it === previous) current else it })
        }
    }

    /** 绑定最后保存的回答身份，便于历史消息显示固定用时。 */
    fun bindAssistant(sessionId: String, messageId: String) {
        worker.execute {
            val previous = records.value.lastOrNull { it.optString("session_id") == sessionId && it.optString("status") == "running" } ?: return@execute
            val current = JSONObject(previous.toString()).put("assistant_message_id", messageId)
            persist(records.value.map { if (it === previous) current else it })
        }
    }

    /** 没有历史测量值时不估算用时。 */
    fun elapsedForMessage(ids: Collection<String>): Long? = records.value.lastOrNull {
        it.optString("assistant_message_id") in ids && it.has("elapsed_ms")
    }?.optLong("elapsed_ms")

    /** 返回独立副本，供会话CLI读取最新轮次和累计有效耗时。 */
    fun summary(sessionId: String): JSONObject {
        val turns = records.value.filter { it.optString("session_id") == sessionId }
        return JSONObject().put("total_elapsed_ms", turns.sumOf { it.optLong("elapsed_ms") })
            .put("turn_count", turns.size)
            .put("last_turn", turns.lastOrNull()?.let { JSONObject(it.toString()).apply { remove("monotonic_ms") } } ?: JSONObject.NULL)
    }

    private fun persist(values: List<JSONObject>) {
        val retained = values.takeLast(1000)
        preferences?.edit()?.putString("records", JSONArray(retained).toString())?.apply()
        records.value = retained.toList()
        revision.value++
    }
}
