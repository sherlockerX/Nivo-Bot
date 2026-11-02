package io.github.nanomuse.routines

import android.content.Context
import com.openminis.app.scheduled.ScheduledRun
import com.openminis.app.scheduled.ScheduledTask
import com.openminis.app.scheduled.ScheduledTaskStore
import org.json.JSONObject
import java.io.File

/** 串行更新计数，随后导出日志与状态；导出失败独立于业务结果。 */
object ScheduledRunRecorder {
    /** 纯结果归约，未知不清零、不增加失败计数。 */
    fun reduce(task: ScheduledTask, run: ScheduledRun, reason: String?): ScheduledTask {
        // 调试运行只追加历史并结算时间槽，不改变失败计数与自动停用。
        if (run.debug) return task.copy(lastFiredAt = run.firedAt, lastResultPreview = run.preview,
            runHistory = (listOf(run) + task.runHistory).take(ScheduledTask.MAX_RUN_HISTORY),
            runtime = task.runtime.copy(lastSettledSlotMs = run.scheduledForMs?.let { maxOf(it, task.runtime.lastSettledSlotMs ?: Long.MIN_VALUE) }
                ?: task.runtime.lastSettledSlotMs))
        val failures = when (run.outcome) {
            "success" -> 0
            "failure" -> task.consecutiveFailures + 1
            else -> task.consecutiveFailures
        }
        val disabled = run.outcome == "failure" && task.autoDisableOnFailure && failures >= task.failureThreshold
        return task.copy(lastFiredAt = run.firedAt, lastResultPreview = run.preview, lastResultSessionId = run.sessionId,
            consecutiveFailures = failures, totalFailures = task.totalFailures + if (run.outcome == "failure") 1 else 0,
            enabled = task.enabled && !disabled, runHistory = (listOf(run) + task.runHistory).take(ScheduledTask.MAX_RUN_HISTORY),
            runtime = task.runtime.copy(unknownRuns = task.runtime.unknownRuns + if (run.outcome == "unknown") 1 else 0,
                lastOutcome = run.outcome, lastReason = reason?.take(200),
                countingSinceMs = task.runtime.countingSinceMs.takeIf { it > 0 } ?: run.startedAtMs ?: run.firedAt,
                lastSuccessMs = if (run.outcome == "success") run.firedAt else task.runtime.lastSuccessMs,
                lastFailureMs = if (run.outcome == "failure") run.firedAt else task.runtime.lastFailureMs,
                autoDisabledAtMs = if (disabled) task.runtime.autoDisabledAtMs ?: run.firedAt else task.runtime.autoDisabledAtMs,
                lastSettledSlotMs = run.scheduledForMs?.let { maxOf(it, task.runtime.lastSettledSlotMs ?: Long.MIN_VALUE) } ?: task.runtime.lastSettledSlotMs))
    }

    /** 自动重派在执行业务之前检查已持久化的时间槽，不依赖有限历史长度。 */
    fun alreadySettled(task: ScheduledTask, slot: Long): Boolean = (task.runtime.lastSettledSlotMs ?: Long.MIN_VALUE) >= slot ||
        task.runHistory.any { it.scheduledForMs == slot }

    /** 同一时间槽或运行身份只结算一次，任务被用户删除后不复活。 */
    fun record(context: Context, store: ScheduledTaskStore, taskId: String, run: ScheduledRun,
        reason: String?, details: JSONObject?): ScheduledTask? = synchronized(LOCK) {
        val journal = journal(context)
        val receiptStaged = run.runId == null || runCatching { journal.stageSettlement(JSONObject().put("task_id", taskId).put("run", run.toJson())
            .put("reason", reason ?: JSONObject.NULL).put("details", details ?: JSONObject.NULL)) }.isSuccess
        var recorded = false
        val updated = store.mutate(taskId) { task ->
            if (run.runId in task.runtime.settledUnackedRunIds || task.runHistory.any { (run.runId != null && it.runId == run.runId) ||
                (run.scheduledForMs != null && it.scheduledForMs == run.scheduledForMs) }) return@mutate task
            recorded = true
            val reduced = reduce(task, run, reason)
            reduced.copy(runtime = reduced.runtime.copy(settledUnackedRunIds =
                task.runtime.settledUnackedRunIds + listOfNotNull(run.runId)))
        } ?: run {
            runCatching { journal.write(taskId, runData(taskId, run, details, details?.optString("label", "task") ?: "task"), null)
                if (run.runId != null) journal.clearSettlement(run) }
            return null // nanoMuse: 任务已删仍保留最后运行日志，不复活状态文件。
        }
        val data = runData(taskId, run, details, updated.label)
        val failed = runCatching { journal.write(taskId, data, state(updated.copy(runtime = updated.runtime.copy(logWriteError = false)))) }.isFailure || !receiptStaged
        val acknowledged = run.runId == null || runCatching { journal.clearSettlement(run) }.isSuccess
        val result = runCatching { store.mutate(taskId) { latest ->
            latest.copy(runtime = latest.runtime.copy(
                logWriteError = if (latest.runHistory.firstOrNull()?.runId == run.runId) failed || !acknowledged else latest.runtime.logWriteError,
                settledUnackedRunIds = if (acknowledged) latest.runtime.settledUnackedRunIds - listOfNotNull(run.runId).toSet() else latest.runtime.settledUnackedRunIds))
        } }.getOrNull() ?: updated.copy(runtime = updated.runtime.copy(logWriteError = true)) // nanoMuse: 诊断标志写失败不阻止业务完成确认。
        if (recorded && !run.debug) ScheduledRunAlerts.changed(context, result, run.outcome)
        return result
    }

    /** 只补写既有运行终态，成功后释放自动运行凭据，不再调用模型或脚本。 */
    fun recover(context: Context) {
        val journal = journal(context)
        journal.maintain()
        journal.settlements().forEach { receipt -> runCatching {
            val run = ScheduledRun.fromJson(receipt.getJSONObject("run"))
            record(context, ScheduledTaskStore(context), receipt.getString("task_id"), run,
                receipt.optString("reason").takeUnless { receipt.isNull("reason") }, receipt.optJSONObject("details"))
            RoutineHeartbeat.finish(context, receipt.getString("task_id"), run.scheduledForMs)
        } }
    }

    /** 未提交的实际结果优先于中断推断，读取异常时保守等待下一次恢复。 */
    fun hasUnsettled(context: Context, runId: String): Boolean = runCatching {
        journal(context).settlements().any { it.getJSONObject("run").optString("runId") == runId }
    }.getOrDefault(true)

    private fun runData(taskId: String, run: ScheduledRun, details: JSONObject?, label: String): JSONObject =
        JSONObject().put("mode", JSONObject.NULL).put("script_id", JSONObject.NULL).put("script_args", org.json.JSONArray())
            .put("trigger", "unknown").put("timezone", java.time.ZoneId.systemDefault().id)
            .put("stdout_bytes", JSONObject.NULL).put("stdout_sha256", JSONObject.NULL).put("stderr_tail", "")
            .put("message_text_bytes", 0).put("stdout_truncated", false).put("capture_available", false)
            .apply { details?.keys()?.forEach { key -> put(key, details.get(key)) } }
            .put("run_id", run.runId).put("task_id", taskId).put("label", label)
            .put("started_at_ms", run.startedAtMs ?: run.firedAt).put("finished_at_ms", run.firedAt)
            .put("duration_ms", run.durationMs ?: 0).put("outcome", run.outcome).put("status", run.status)
            .put("exit_code", run.exitCode ?: JSONObject.NULL).put("session_id", run.sessionId ?: JSONObject.NULL)

    /** 删除与运行状态投影共用锁，不能在删除后重建状态。 */
    fun delete(context: Context, store: ScheduledTaskStore, taskId: String) = synchronized(LOCK) {
        store.delete(taskId)
        runCatching { journal(context).deleteState(taskId) }
    }

    /** CLI与落盘状态使用同一投影；异常时CLI明确标记镜像写入失败。 */
    fun state(task: ScheduledTask): JSONObject = JSONObject().put("task_id", task.id)
        .put("consecutive_failures", task.consecutiveFailures).put("total_failures", task.totalFailures)
        .put("unknown_runs", task.runtime.unknownRuns).put("last_run_ms", task.lastFiredAt ?: JSONObject.NULL)
        .put("last_success_ms", task.runtime.lastSuccessMs ?: JSONObject.NULL).put("last_failure_ms", task.runtime.lastFailureMs ?: JSONObject.NULL)
        .put("last_exit_code", task.runHistory.firstOrNull()?.exitCode ?: JSONObject.NULL)
        .put("last_outcome", task.runtime.lastOutcome).put("last_reason", task.runtime.lastReason ?: JSONObject.NULL)
        .put("auto_disabled_at_ms", task.runtime.autoDisabledAtMs ?: JSONObject.NULL).put("counting_since_ms", task.runtime.countingSinceMs)
        .put("log_write_error", task.runtime.logWriteError)

    /** 定位账户隔离的持久home，不通过模型或Shell写日志。 */
    fun journal(context: Context) = ScheduledRunJournal(File(context.filesDir, "minis-global/home"))

    private val LOCK = Any()
}
