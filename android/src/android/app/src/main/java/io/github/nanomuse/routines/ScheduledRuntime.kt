package io.github.nanomuse.routines

import org.json.JSONObject

/** 无明确成功证据的提示词运行保持未知，不以正常结束冒充业务成功。 */
enum class RunOutcome(val wire: String) { SUCCESS("success"), FAILURE("failure"), UNKNOWN("unknown") }

/** 持久计数只描述启用新判定规则之后的运行，不猜测历史结果。 */
data class ScheduledRuntime(
    val unknownRuns: Int = 0,
    val lastOutcome: String = "unknown",
    val lastReason: String? = null,
    val countingSinceMs: Long = System.currentTimeMillis(),
    val lastSuccessMs: Long? = null,
    val lastFailureMs: Long? = null,
    val autoDisabledAtMs: Long? = null,
    val logWriteError: Boolean = false,
    val lastSettledSlotMs: Long? = null,
    val settledUnackedRunIds: Set<String> = emptySet(),
) {
    /** 向兼容的任务对象追加元数据，不改变旧字段。 */
    fun write(target: JSONObject) {
        target.put("unknownRuns", unknownRuns).put("lastOutcome", lastOutcome)
            .put("lastReason", lastReason ?: JSONObject.NULL).put("countingSinceMs", countingSinceMs)
            .put("lastSuccessMs", lastSuccessMs ?: JSONObject.NULL).put("lastFailureMs", lastFailureMs ?: JSONObject.NULL)
            .put("autoDisabledAtMs", autoDisabledAtMs ?: JSONObject.NULL).put("logWriteError", logWriteError)
            .put("lastSettledSlotMs", lastSettledSlotMs ?: JSONObject.NULL)
            .put("settledUnackedRunIds", org.json.JSONArray(settledUnackedRunIds.toList()))
    }

    companion object {
        /** 旧记录保持未知，起算时间在存储迁移时落盘。 */
        fun read(source: JSONObject) = ScheduledRuntime(
            unknownRuns = source.optInt("unknownRuns"), lastOutcome = source.optString("lastOutcome", "unknown"),
            lastReason = source.optString("lastReason", "").takeIf { it.isNotBlank() && it != "null" },
            countingSinceMs = source.optLong("countingSinceMs", 0),
            lastSuccessMs = source.nullableLong("lastSuccessMs"), lastFailureMs = source.nullableLong("lastFailureMs"),
            autoDisabledAtMs = source.nullableLong("autoDisabledAtMs"), logWriteError = source.optBoolean("logWriteError"),
            lastSettledSlotMs = source.nullableLong("lastSettledSlotMs"),
            settledUnackedRunIds = source.optJSONArray("settledUnackedRunIds")?.let { array ->
                (0 until array.length()).map { array.getString(it) }.toSet()
            }.orEmpty(),
        )
        private fun JSONObject.nullableLong(key: String) = if (has(key) && !isNull(key)) getLong(key) else null
    }
}
