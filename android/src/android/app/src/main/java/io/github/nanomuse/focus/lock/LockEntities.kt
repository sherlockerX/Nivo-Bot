package io.github.nanomuse.focus.lock

import androidx.room.Entity
import androidx.room.Index
import org.json.JSONArray
import org.json.JSONObject

/** 账号内的锁机计划，软删除和修订信息只属于持久化层。 */
@Entity(tableName = "focus_lock_plans", primaryKeys = ["ownerKey", "id"])
data class LockPlanEntity(
    val ownerKey: String,
    val id: String,
    val name: String,
    val enabled: Boolean,
    val daysMask: Int,
    val rangesJson: String,
    val useWhitelist: Boolean,
    val title: String?,
    val taskId: String?,
    val revision: Long,
    val updatedAt: Long,
    val deletedAt: Long? = null
) {
    /** 还原日历计划；无效掩码和区间直接拒绝，不能静默改成其他时段。 */
    fun toModel(): LockPlan {
        require(daysMask in 0..127) { "星期掩码只能使用低七位" }
        val rangeArray = JSONArray(rangesJson)
        val ranges = List(rangeArray.length()) { index ->
            val range = rangeArray.getJSONObject(index)
            TimeRange(readMinute(range, "startMinute"), readMinute(range, "endMinute"))
        }
        return LockPlan(
            id = id, name = name,
            days = (1..7).filterTo(linkedSetOf()) { day -> daysMask and (1 shl (day - 1)) != 0 },
            ranges = ranges, isEnabled = enabled, usesWhitelist = useWhitelist,
            title = title, taskId = taskId, ownerKey = ownerKey, revision = revision
        )
    }

    companion object {
        /** 保存计划和调用方确定的变更时间，保持区间顺序和账号身份。 */
        fun fromModel(
            model: LockPlan,
            updatedAt: Long,
            deletedAt: Long? = null
        ): LockPlanEntity {
            val ranges = JSONArray()
            model.ranges.forEach { range ->
                ranges.put(JSONObject().put("startMinute", range.startMinute).put("endMinute", range.endMinute))
            }
            return LockPlanEntity(
                ownerKey = model.ownerKey, id = model.id, name = model.name,
                enabled = model.isEnabled,
                daysMask = model.days.fold(0) { mask, day -> mask or (1 shl (day - 1)) },
                rangesJson = ranges.toString(), useWhitelist = model.usesWhitelist,
                title = model.title, taskId = model.taskId, revision = model.revision,
                updatedAt = updatedAt, deletedAt = deletedAt
            )
        }
    }
}

/** 每个账号单独保存的全局应用白名单。 */
@Entity(tableName = "focus_lock_whitelist", primaryKeys = ["ownerKey", "packageName"])
data class LockWhitelistEntity(
    val ownerKey: String,
    val packageName: String,
    val addedAt: Long
)

/** 锁定记录只关联已有专注身份，不改变普通专注表的字段。 */
@Entity(
    tableName = "focus_lock_runs",
    primaryKeys = ["ownerKey", "id"],
    indices = [
        Index(value = ["ownerKey", "sessionId"], unique = true),
        Index(value = ["ownerKey", "status"])
    ]
)
data class LockRunEntity(
    val ownerKey: String,
    val id: String,
    val sessionId: String,
    val planIds: String,
    val occurrenceIds: String,
    val startedAt: Long,
    val deadlineAt: Long,
    val durationMs: Long,
    val useWhitelist: Boolean,
    val checkpointRemainingMs: Long,
    val checkpointElapsed: Long,
    val bootCount: Int,
    val status: String,
    val endedAt: Long? = null
) {
    /** 恢复纯计时模型，任何负启动号都必须重新建立时钟检查点。 */
    fun toModel(): LockRun = LockRun(
        ownerKey = ownerKey, id = id, sessionId = sessionId,
        planIds = decodeIdentifiers(planIds), occurrenceIds = decodeIdentifiers(occurrenceIds),
        startedAt = startedAt, deadlineAt = deadlineAt, durationMs = durationMs,
        usesWhitelist = useWhitelist, checkpointRemainingMs = checkpointRemainingMs,
        checkpointElapsed = checkpointElapsed, bootCount = persistentBootCount(bootCount),
        status = when (status) {
            "active" -> LockRunStatus.ACTIVE
            "completed" -> LockRunStatus.COMPLETED
            "emergency" -> LockRunStatus.EMERGENCY
            else -> throw IllegalArgumentException("未知锁机状态：$status")
        },
        endedAt = endedAt
    )

    companion object {
        /** 保存固定截止与检查点；进程内临时启动号不能跨进程复用。 */
        fun fromModel(model: LockRun): LockRunEntity = LockRunEntity(
            ownerKey = model.ownerKey, id = model.id, sessionId = model.sessionId,
            planIds = JSONArray(model.planIds.sorted()).toString(),
            occurrenceIds = JSONArray(model.occurrenceIds.sorted()).toString(),
            startedAt = model.startedAt, deadlineAt = model.deadlineAt, durationMs = model.durationMs,
            useWhitelist = model.usesWhitelist, checkpointRemainingMs = model.checkpointRemainingMs,
            checkpointElapsed = model.checkpointElapsed, bootCount = persistentBootCount(model.bootCount),
            status = model.status.name.lowercase(), endedAt = model.endedAt
        )
    }
}

private fun persistentBootCount(bootCount: Int): Int = if (bootCount >= 0) bootCount else -1

private fun readMinute(range: JSONObject, field: String): Int {
    val value = range.get(field)
    require(value is Int || value is Long) { "计划分钟必须是整数" }
    val minute = (value as Number).toLong()
    require(minute in 0L..1439L) { "计划分钟必须位于一天之内" }
    return minute.toInt()
}

private fun decodeIdentifiers(value: String): Set<String> {
    val identifiers = JSONArray(value)
    return (0 until identifiers.length()).mapTo(linkedSetOf()) { index ->
        val identifier = identifiers.get(index)
        require(identifier is String) { "计划和时段身份必须是字符串" }
        identifier
    }
}
