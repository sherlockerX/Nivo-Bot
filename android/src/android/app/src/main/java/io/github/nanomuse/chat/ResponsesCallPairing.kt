package io.github.nanomuse.chat

import com.openminis.app.logging.AppLogger
import org.json.JSONArray
import org.json.JSONObject

/**
 * 整理Responses请求里的工具调用：`call_id`、`function_call.id`和结果数量一起核对。
 *
 * 服务端要求整个输入里两种编号都唯一，并且每个调用都有结果。历史里会出现两种重复：
 * 模型真的用同一编号调用了多次，每次都有自己的结果，这时改名并保持配对；
 * 同一个调用被重放了一遍，却只有一个真实结果，这时去掉多出来的调用。
 */
internal object ResponsesCallPairing {
    private const val TAG = "ResponsesCallPairing"
    private const val MAX_ID_LENGTH = 64

    private class Call(val index: Int, val batch: Int, val rawId: String, val signature: String) {
        var output: Int? = null
    }

    /** 返回整理后的输入，原对象里的编号会被改写。 */
    fun normalize(input: JSONArray): JSONArray {
        val items = (0 until input.length()).map { input.opt(it) }
        val calls = pair(items)
        val repeatedOutputs = outputsWithoutCall(items, calls)
        val replayed = replayedCalls(calls)
        rename(items, calls.filter { it !in replayed })

        if (replayed.isEmpty() && repeatedOutputs.isEmpty()) return input
        AppLogger.warning(TAG, "dropped ${replayed.size} replayed call(s) and ${repeatedOutputs.size} extra output(s)")
        val dropped = replayed.map { it.index }.toSet() + repeatedOutputs
        return JSONArray().apply { items.forEachIndexed { index, item -> if (index !in dropped) put(item) } }
    }

    /** 结果交给最近一批里最早还没有结果的同编号调用；一批是连续的几个调用。 */
    private fun pair(items: List<Any?>): List<Call> {
        val calls = mutableListOf<Call>()
        var batch = 0
        var isInBatch = false
        items.forEachIndexed { index, item ->
            val isCall = type(item) == "function_call"
            if (isCall && !isInBatch) batch += 1
            isInBatch = isCall
            val rawId = callId(item) ?: return@forEachIndexed
            if (isCall) {
                calls += Call(index, batch, rawId, signature(item as JSONObject))
            } else if (type(item) == "function_call_output") {
                val waiting = calls.filter { it.rawId == rawId && it.output == null }
                val latest = waiting.maxOfOrNull { it.batch }
                waiting.firstOrNull { it.batch == latest }?.output = index
            }
        }
        return calls
    }

    /** 调用已经有结果之后又出现的同编号结果；找不到调用的结果保持原样。 */
    private fun outputsWithoutCall(items: List<Any?>, calls: List<Call>): Set<Int> {
        val paired = calls.mapNotNull { it.output }.toSet()
        val knownIds = calls.map { it.rawId }.toSet()
        return items.indices.filter { index ->
            type(items[index]) == "function_call_output" && index !in paired && callId(items[index]) in knownIds
        }.toSet()
    }

    /** 没有结果、内容又与另一个调用完全相同的调用；都没有结果时留下最早的一个。 */
    private fun replayedCalls(calls: List<Call>): Set<Call> = calls.groupBy { it.signature }.values.flatMap { same ->
        val unanswered = same.filter { it.output == null }
        if (unanswered.size == same.size) unanswered.drop(1) else unanswered
    }.toSet()

    private fun rename(items: List<Any?>, calls: List<Call>) {
        val usedCallIds = HashSet<String>()
        val usedItemIds = items.filter { type(it) != "function_call" }
            .mapNotNullTo(HashSet()) { (it as? JSONObject)?.optString("id")?.ifEmpty { null } }
        val occurrences = HashMap<String, Int>()
        for (call in calls) {
            val item = items[call.index] as JSONObject
            val (callId, occurrence) = unique(call.rawId, (occurrences[call.rawId] ?: 0) + 1, "-", usedCallIds)
            occurrences[call.rawId] = occurrence
            item.put("call_id", callId)
            call.output?.let { (items[it] as JSONObject).put("call_id", callId) }
            val itemId = item.optString("id").ifEmpty { null } ?: continue
            item.put("id", unique(itemId, 1, "_", usedItemIds).first)
        }
    }

    /** 第一次出现保留原编号，之后加序号；超长时截短原编号给序号留位置。 */
    private fun unique(raw: String, start: Int, separator: String, used: MutableSet<String>): Pair<String, Int> {
        var occurrence = start
        while (true) {
            val suffix = if (occurrence == 1) "" else "$separator$occurrence"
            val candidate = raw.take(MAX_ID_LENGTH - suffix.length) + suffix
            if (used.add(candidate)) return candidate to occurrence
            occurrence += 1
        }
    }

    private fun type(item: Any?): String? = (item as? JSONObject)?.optString("type")

    private fun callId(item: Any?): String? = (item as? JSONObject)?.optString("call_id")?.ifEmpty { null }

    private fun signature(item: JSONObject): String =
        listOf("call_id", "id", "name", "arguments").joinToString("\u0000") { item.optString(it) }
}
