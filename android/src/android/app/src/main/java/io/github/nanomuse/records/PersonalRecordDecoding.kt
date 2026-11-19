package io.github.nanomuse.records

import com.openminis.app.scheduled.ScheduledTask
import io.github.nanomuse.goals.Goal
import org.json.JSONArray
import org.json.JSONObject

/** 历史文件损坏必须显式失败，不把损坏的子记录丢弃或补造成成功证据。 */
internal object PersonalRecordDecoding {
    /** 允许旧记录缺少时间，但不以查询时刻替代未知的创建时间。 */
    fun goals(raw: String): List<Goal> = decode(raw) { row ->
        validateChildren(row, "steps") { step ->
            require(step.opt("text") is String) { "A goal step has no saved text" }
            optionalBoolean(step, "done")
        }
        optionalNumber(row, "progress")
        optionalNumber(row, "createdAt")
        optionalNumber(row, "updatedAt")
        Goal.fromJson(row).copy(createdAt = row.optLong("createdAt", 0), updatedAt = row.optLong("updatedAt", 0))
    }

    /** 运行时间与成功状态必须来自存档，不能沿用展示层的缺省成功值。 */
    fun routines(raw: String): List<ScheduledTask> = decode(raw) { row ->
        validateChildren(row, "runHistory", ::validateRun)
        optionalNumber(row, "createdAt")
        optionalBoolean(row, "enabled")
        ScheduledTask.fromJson(row).copy(createdAt = row.optLong("createdAt", 0))
    }

    private fun validateRun(row: JSONObject) {
        require(row.opt("ok") is Boolean) { "A saved routine run has no explicit outcome" }
        require(row.opt("firedAt") is Number && row.getLong("firedAt") > 0) { "A saved routine run has no valid time" }
        optionalNumber(row, "durationMs")
        optionalNumber(row, "startedAtMs")
        optionalNumber(row, "scheduledForMs")
        if (row.has("status")) require(row.opt("status") is String && row.getString("status").isNotBlank()) {
            "A saved routine run has an invalid status"
        }
    }

    private fun validateChildren(row: JSONObject, key: String, validate: (JSONObject) -> Unit) {
        if (!row.has(key)) return
        val children = row.opt(key) as? JSONArray ?: error("Saved $key is not an array")
        repeat(children.length()) { index -> validate(children.getJSONObject(index)) }
    }

    private fun optionalBoolean(row: JSONObject, key: String) {
        if (row.has(key)) require(row.opt(key) is Boolean) { "Saved $key is not a boolean" }
    }

    private fun optionalNumber(row: JSONObject, key: String) {
        if (row.has(key)) require(row.opt(key) is Number) { "Saved $key is not a number" }
    }

    private fun <T> decode(raw: String, read: (JSONObject) -> T): List<T> {
        val items = JSONArray(raw)
        val seenIds = mutableSetOf<String>()
        return List(items.length()) { index ->
            val row = items.getJSONObject(index)
            val id = row.opt("id") as? String
            require(!id.isNullOrBlank() && seenIds.add(id)) { "A saved record has a missing or duplicate ID" }
            read(row)
        }
    }
}
