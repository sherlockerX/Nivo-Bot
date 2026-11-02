package io.github.nanomuse.routines

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.SystemClock
import com.openminis.app.scheduled.*
import kotlinx.coroutines.*
import org.json.JSONObject

/** 十分钟补偿扫描，与任务闹钟共用领取记录，进程重启后保留待派发任务。 */
object RoutineHeartbeat {
    private const val INTERVAL_MS = 10 * 60_000L
    private const val LEASE_MS = 12 * 60_000L
    private val lock = Any()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO + CoroutineExceptionHandler { _, error ->
        android.util.Log.w("RoutineHeartbeat", "heartbeat recovery failed", error)
    })
    private fun prefs(context: Context) = context.getSharedPreferences("nm_routine_heartbeat", Context.MODE_PRIVATE)

    /** 初始化只恢复计划和扫描，不创建空转前台服务。 */
    fun init(context: Context) {
        val app = context.applicationContext
        scope.launch {
            ScheduledTaskManager(app).rescheduleAll()
            tick(app)
        }
    }

    /** 每个任务保存实际已安排的时间，重启或补查不把时间向后推。 */
    fun rememberDue(context: Context, taskId: String, proposed: Long, replace: Boolean = false): Long = synchronized(lock) {
        val storage = prefs(context)
        if (!replace && storage.contains("due:$taskId")) return@synchronized storage.getLong("due:$taskId", proposed)
        check(storage.edit().putLong("due:$taskId", proposed).commit())
        proposed
    }

    /** 用户停用、删除或修改计划时取消旧时间槽及待派发记录。 */
    fun forget(context: Context, taskId: String, keepPending: Boolean = false) = synchronized(lock) {
        val editor = prefs(context).edit().remove("due:$taskId")
        if (!keepPending) editor.remove("pending:$taskId")
        check(editor.commit())
    }

    /** 自动入口只领取到期的同一时间槽一次；手动运行不经过此入口。 */
    suspend fun fire(context: Context, task: ScheduledTask, expected: Long? = null) {
        val due = synchronized(lock) {
            val storage = prefs(context)
            val planned = storage.getLong("due:${task.id}", expected ?: Long.MAX_VALUE)
            if (!task.enabled || planned > System.currentTimeMillis() || (expected != null && expected != planned)) return
            if (storage.contains("pending:${task.id}")) return
            val pending = JSONObject().put("task", task.toJson()).put("due", planned).put("lease", 0L)
                .put("run_id", java.util.UUID.randomUUID().toString()).put("dispatched", false) // nanoMuse: 业务派发前持久化运行身份。
            check(storage.edit().putString("pending:${task.id}", pending.toString()).commit())
            planned
        }
        // 先持久化领取记录再推进计划，即使派发失败也能从 pending 恢复。
        ScheduledTaskManager(context).rescheduleNext(task.id)
        dispatchPending(context, task.id, due)
    }

    /** 完成已派发任务后确认时间槽，不把失败的模型执行自动重放。 */
    fun finish(context: Context, taskId: String, scheduledFor: Long?) = synchronized(lock) {
        if (scheduledFor == null) return@synchronized
        val storage = prefs(context)
        val raw = storage.getString("pending:$taskId", null) ?: return@synchronized
        if (JSONObject(raw).optLong("due") == scheduledFor) check(storage.edit().remove("pending:$taskId").commit())
    }

    /** 扫描到期任务和启动失败的待派发任务，合并错过的重复时间槽。 */
    suspend fun tick(context: Context) {
        try {
            runCatching { ScheduledRunRecorder.recover(context) }
            val tasks = ScheduledTaskManager(context).list()
            for (task in tasks.filter { it.enabled }) {
                runCatching { fire(context, task) }
            }
            val pendingIds = synchronized(lock) {
                prefs(context).all.keys.filter { it.startsWith("pending:") }.map { it.removePrefix("pending:") }
            }
            for (id in pendingIds) runCatching { dispatchPending(context, id) }
        } finally { scheduleTick(context) }
    }

    private suspend fun dispatchPending(context: Context, id: String, expected: Long? = null) {
        val pending = synchronized(lock) {
            val storage = prefs(context)
            val raw = storage.getString("pending:$id", null) ?: return
            val record = JSONObject(raw)
            if (record.optLong("lease") > System.currentTimeMillis()) return
            if (expected != null && record.optLong("due") != expected) return
            if (!record.has("run_id")) {
                if (record.optLong("lease") > 0) record.put("dispatched", true) // nanoMuse: 老版已领取但结果不明的运行不自动重放。
                record.put("run_id", java.util.UUID.randomUUID().toString())
            }
            record.put("lease", System.currentTimeMillis() + LEASE_MS)
            check(storage.edit().putString("pending:$id", record.toString()).commit())
            record
        }
        try {
            val task = ScheduledTask.fromJson(pending.getJSONObject("task"))
            val current = ScheduledTaskStore(context).get(task.id)
            val slot = pending.getLong("due")
            if (current == null || ScheduledRunRecorder.alreadySettled(current, slot)) { finish(context, id, slot); return }
            if (pending.optBoolean("dispatched")) {
                if (ScheduledRunRecorder.hasUnsettled(context, pending.getString("run_id"))) return
                if (ScheduledRunScopes.hasTask(id)) return
                ScheduledTaskManager(context).markFired(id, null, "RUN_INTERRUPTED", ok = false, scheduledForMs = slot,
                    startedAtMs = pending.optLong("started_at_ms", slot), status = "aborted", runId = pending.getString("run_id"),
                    reason = "RUN_INTERRUPTED", details = JSONObject().put("trigger", "schedule").put("error", "RUN_INTERRUPTED")
                        .put("mode", if (task.scriptId == null) "prompt" else "script").put("script_id", task.scriptId ?: JSONObject.NULL)
                        .put("script_args", org.json.JSONArray(task.scriptArgs)).put("message_text_bytes", 0).put("capture_available", false))
                finish(context, id, slot)
                return
            }
            // 恢复进程在领取后、推进计划前退出的情况。
            if (prefs(context).getLong("due:$id", -1L) == pending.getLong("due")) ScheduledTaskManager(context).rescheduleNext(id)
            synchronized(lock) {
                val raw = prefs(context).getString("pending:$id", null) ?: return
                val checkpoint = JSONObject(raw).put("dispatched", true).put("started_at_ms", System.currentTimeMillis())
                check(prefs(context).edit().putString("pending:$id", checkpoint.toString()).commit())
            }
            val session = ScheduledAgentRunner.run(context, task, waitForCompletion = false, firedTriggerAtMs = pending.getLong("due"),
                persistentRunId = pending.getString("run_id"))
            if (session == null) releaseLease(context, id, pending.getLong("due"))
        } catch (error: Exception) {
            releaseLease(context, id, pending.getLong("due"))
            if (error is CancellationException) throw error
        }
    }

    private fun releaseLease(context: Context, id: String, due: Long) = synchronized(lock) {
        val storage = prefs(context)
        val raw = storage.getString("pending:$id", null) ?: return@synchronized
        val record = JSONObject(raw)
        if (record.optLong("due") == due) check(storage.edit().putString("pending:$id", record.put("lease", 0L).toString()).commit())
    }

    private fun scheduleTick(context: Context) {
        val alarm = context.getSystemService(AlarmManager::class.java)
        val intent = Intent(context, RoutineHeartbeatReceiver::class.java).setAction("io.github.nanomuse.ROUTINE_HEARTBEAT")
        val pending = PendingIntent.getBroadcast(context, 0, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        alarm.setAndAllowWhileIdle(AlarmManager.ELAPSED_REALTIME_WAKEUP, SystemClock.elapsedRealtime() + INTERVAL_MS, pending)
    }
}

/** 广播只做短交接，执行模型的协程由现有任务运行器持有。 */
class RoutineHeartbeatReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val result = goAsync()
        CoroutineScope(SupervisorJob() + Dispatchers.IO).launch {
            try { withTimeout(8_000L) { RoutineHeartbeat.tick(context.applicationContext) } }
            catch (error: Exception) { android.util.Log.w("RoutineHeartbeat", "heartbeat handoff deferred", error) }
            finally { result.finish() }
        }
    }
}
