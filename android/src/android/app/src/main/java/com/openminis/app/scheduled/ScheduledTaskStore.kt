package com.openminis.app.scheduled

import android.content.Context
import com.openminis.app.logging.AppLogger
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow
import org.json.JSONArray

/**
 * [T-android-scheduled-tasks-design] SharedPreferences-backed JSON array of
 * [ScheduledTask] rows. Same pattern as [com.openminis.app.offload.AlarmOffloadManager]
 * — small dataset, low write frequency, no Room migration cost.
 */
class ScheduledTaskStore(private val context: Context) {

    private val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    init { // nanoMuse: 迁移前先备份，旧任务不推测来源或回填历史成功。
        synchronized(MUTATION_LOCK) {
            val raw = prefs.getString(KEY_TASKS, null)
            val files = context.filesDir
            if (raw != null && files != null && !prefs.getBoolean("nm_runtime_v2", false)) {
                runCatching {
                    io.github.nanomuse.routines.ScheduledRunJournal(java.io.File(files, "minis-global/home")).backupTasks(raw)
                    val now = System.currentTimeMillis()
                    write(all().map { task -> task.copy(runtime = task.runtime.copy(
                        countingSinceMs = task.runtime.countingSinceMs.takeIf { it > 0 } ?: now)) }, durable = true)
                    check(prefs.edit().putBoolean("nm_runtime_v2", true).commit())
                }.onFailure { AppLogger.warning(TAG, "Task metadata backup or migration failed") }
            }
        }
    }

    fun all(): List<ScheduledTask> {
        val raw = prefs.getString(KEY_TASKS, null) ?: return emptyList()
        return try {
            val arr = JSONArray(raw)
            buildList {
                for (i in 0 until arr.length()) {
                    val o = arr.optJSONObject(i) ?: continue
                    runCatching { ScheduledTask.fromJson(o) }
                        .onSuccess { add(it) }
                        .onFailure { AppLogger.warning(TAG, "skip malformed row: ${it.message}") }
                }
            }
        } catch (t: Throwable) {
            AppLogger.warning(TAG, "load failed: ${t.message}")
            emptyList()
        }
    }

    fun get(taskId: String): ScheduledTask? = all().firstOrNull { it.id == taskId }

    fun upsert(task: ScheduledTask, rejectDuplicate: Boolean = false) = synchronized(MUTATION_LOCK) { // nanoMuse: 跨实例串行化读改写。
        val current = all().filter { it.id != task.id }
        if (rejectDuplicate) require(current.none { io.github.nanomuse.routines.ScheduledTaskIdentity.same(it, task) }) { "An identical scheduled task already exists" }
        val latest = get(task.id) // nanoMuse: 计划编辑与后台完成竞争时，运行元数据以锁内最新值为准。
        val replacement = if (latest == null) task else task.copy(runHistory = latest.runHistory,
            lastFiredAt = latest.lastFiredAt, lastResultPreview = latest.lastResultPreview, lastResultSessionId = latest.lastResultSessionId,
            consecutiveFailures = latest.consecutiveFailures, totalFailures = latest.totalFailures,
            runtime = latest.runtime) // nanoMuse: 编辑不能覆盖后台运行状态。
        write(current + replacement)
    }

    /** nanoMuse: 基于锁内最新记录修改，任务完成不能覆盖用户刚编辑的计划。 */
    fun mutate(taskId: String, transform: (ScheduledTask) -> ScheduledTask): ScheduledTask? = synchronized(MUTATION_LOCK) {
        val current = get(taskId) ?: return@synchronized null
        val updated = transform(current)
        write(all().filter { it.id != taskId } + updated, durable = true) // nanoMuse: 运行结算持久化后才返回。
        updated
    }

    fun delete(taskId: String) = synchronized(MUTATION_LOCK) { // nanoMuse
        write(all().filter { it.id != taskId }, durable = true)
    }

    fun clear() = synchronized(MUTATION_LOCK) { // nanoMuse
        prefs.edit().remove(KEY_TASKS).apply()
    }

    private fun write(tasks: List<ScheduledTask>, durable: Boolean = false) {
        val arr = JSONArray()
        for (t in tasks) arr.put(t.toJson())
        val editor = prefs.edit().putString(KEY_TASKS, arr.toString())
        if (durable) check(editor.commit()) { "TASK_STATE_WRITE_FAILED" } else editor.apply() // nanoMuse
    }

    /**
     * Cold flow that emits the current task list whenever the prefs file
     * changes. Used by [ScheduledTasksViewModel] to keep the list screen
     * live.
     */
    fun observe(): Flow<List<ScheduledTask>> = callbackFlow {
        trySend(all())
        val listener = android.content.SharedPreferences.OnSharedPreferenceChangeListener { _, key ->
            if (key == KEY_TASKS || key == null) {
                trySend(all())
            }
        }
        prefs.registerOnSharedPreferenceChangeListener(listener)
        awaitClose { prefs.unregisterOnSharedPreferenceChangeListener(listener) }
    }

    companion object {
        private val MUTATION_LOCK = Any() // nanoMuse: 所有存储实例共用。
        private const val TAG = "ScheduledTaskStore"
        private const val PREFS_NAME = "minis_scheduled_tasks_prefs"
        private const val KEY_TASKS = "tasks_json"
    }
}
