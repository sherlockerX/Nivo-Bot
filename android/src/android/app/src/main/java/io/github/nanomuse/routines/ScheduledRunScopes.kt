package io.github.nanomuse.routines

import org.json.JSONObject
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

/** 一次任务运行的身份与最后一次自报结果，不接受其他会话伪造上下文。 */
class ScheduledRunScope(val taskId: String, val startedAtMs: Long = System.currentTimeMillis(), val trigger: String = "manual", val script: Boolean = false,
    providedRunId: String? = null) {
    val runId: String = providedRunId?.let { UUID.fromString(it).toString() } ?: UUID.randomUUID().toString()
    val monotonicStart: Long = System.nanoTime()
    @Volatile var report: Pair<RunOutcome, String?>? = null
        private set

    private val token = ByteArray(32).also { java.security.SecureRandom().nextBytes(it) }.joinToString("") { "%02x".format(it.toInt() and 255) }
    private val roots = ConcurrentHashMap.newKeySet<Int>()

    /** 只有宿主启动器可以登记实际进程，不接受命令参数里的PID声明。 */
    fun registerProcess(pid: Int?) { if (pid != null && pid > 0) roots.add(pid) }

    /** 运行令牌不公开持久化，并同时验证内核连接对端。 */
    fun authentic(environment: Map<String, String>, peerPid: Int?): Boolean = peerPid != null &&
        environment["MINIS_RUN_TOKEN"] == token && ScheduledProcessIdentity.belongsTo(peerPid, roots)

    /** 本次运行显式交出的结果正文，优先于模型最后一段话。 */
    @Volatile var result: String? = null
        private set

    /** 替换本次运行的最后一次有效上报；状态与结果可以分开报。 */
    fun report(status: String?, reason: String?, result: String? = null) {
        require(status != null || result != null) { "--status or --result required" }
        require(result == null || result.length <= ScheduledResult.MAX_CHARS) { "REPORT_RESULT_TOO_LONG" }
        if (status != null) {
            val outcome = RunOutcome.entries.firstOrNull { it.wire == status && it != RunOutcome.UNKNOWN }
                ?: throw IllegalArgumentException("INVALID_REPORT_STATUS")
            require(reason == null || reason.codePointCount(0, reason.length) <= 200) { "REPORT_REASON_TOO_LONG" }
            report = outcome to reason
        }
        if (result != null) this.result = result
    }

    /** 只注入任务身份，不把上报能力永久留给后续普通对话。 */
    fun environment(): Map<String, String> = mapOf("MINIS_TASK_ID" to taskId, "MINIS_RUN_ID" to runId,
        "MINIS_TRIGGER" to trigger, "TZ" to java.time.ZoneId.systemDefault().id, "MINIS_RUN_TOKEN" to token)
}

/** 在途任务的会话隔离上下文，结束后所有上报立即失效。 */
object ScheduledRunScopes {
    private val active = ConcurrentHashMap<String, ScheduledRunScope>()

    /** 同一会话不能同时绑定两次任务运行。 */
    fun enter(sessionId: String, scope: ScheduledRunScope): Boolean = active.putIfAbsent(sessionId, scope) == null

    /** 仅移除本次绑定，不清除后来启动的其他运行。 */
    fun leave(sessionId: String, scope: ScheduledRunScope) { active.remove(sessionId, scope) }

    /** 普通命令不带任务环境，运行中的命令使用当前上下文。 */
    fun environment(sessionId: String): Map<String, String> = active[sessionId]?.environment().orEmpty()

    /** 宿主将当前持久Shell的可信进程绑定到该次任务。 */
    fun registerProcess(sessionId: String, pid: Int?) { active[sessionId]?.registerProcess(pid) }

    /** 包括等待审批或清理的任务，删除守卫不能只检查UI流式状态。 */
    fun isActive(sessionId: String): Boolean = active.containsKey(sessionId)

    /** 区分本进程仍在执行与进程中断留下的持久派发标记。 */
    fun hasTask(taskId: String): Boolean = active.values.any { it.taskId == taskId }

    /** 同一会话的普通输入不能抢占在途任务，其他会话不受影响。 */
    fun canStartChat(sessionId: String, taskRunId: String?): Boolean = active[sessionId]?.let { it.runId == taskRunId } ?: true

    /**
     * 校验会话和两项运行身份，防止任务外的旧环境被继续使用。返回给调用方的回执；
     * Mosaic: 脚本运行的回执为空，它的stdout会被整段捕获，回执写进去就成了结果正文，退出码0即已接受。
     */
    fun report(sessionId: String?, environment: Map<String, String>, status: String?, reason: String?, peerPid: Int? = null,
        result: String? = null): String {
        val scope = sessionId?.let(active::get) ?: throw IllegalArgumentException("NOT_IN_TASK_RUN")
        require(environment["MINIS_TASK_ID"] == scope.taskId && environment["MINIS_RUN_ID"] == scope.runId) { "NOT_IN_TASK_RUN" }
        require(scope.authentic(environment, peerPid)) { "NOT_IN_TASK_RUN" }
        scope.report(status, reason, result)
        if (scope.script) return ""
        return JSONObject().put("task_id", scope.taskId).put("run_id", scope.runId).put("outcome", status ?: JSONObject.NULL)
            .put("result_bytes", result?.toByteArray(Charsets.UTF_8)?.size ?: JSONObject.NULL).toString()
    }

    /** 传输错误、超时或取消优先于先前的成功上报。Mosaic: 脚本退出码0但明确上报失败时记失败。 */
    fun outcome(scope: ScheduledRunScope, failed: Boolean, scriptExit: Int?, emptyRequired: Boolean): RunOutcome = when {
        failed || emptyRequired -> RunOutcome.FAILURE
        scriptExit != null -> if (scriptExit == 0 && scope.report?.first != RunOutcome.FAILURE) RunOutcome.SUCCESS else RunOutcome.FAILURE
        else -> scope.report?.first ?: RunOutcome.UNKNOWN
    }
}
