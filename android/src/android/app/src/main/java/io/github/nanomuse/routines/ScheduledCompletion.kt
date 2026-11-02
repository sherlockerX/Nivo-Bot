package io.github.nanomuse.routines

/** 本轮不可变收据，CLI不再读取可能已被其他并发轮次覆盖的任务状态。 */
data class ScheduledCompletion(
    val outcome: RunOutcome, val exitCode: Int?, val status: String, val runId: String,
    val stateWriteError: Boolean = false,
    val sessionId: String? = null, // 不建会话的脚本运行为 null。
    val result: ScheduledResult? = null,
    val notify: ScheduledResultNotifier.Decision? = null,
) {
    /** 只有确认成功返回0，未知使用独立退出码且不计入失败计数。 */
    fun cliExitCode(): Int = when (outcome) {
        RunOutcome.SUCCESS -> 0
        RunOutcome.UNKNOWN -> 3
        RunOutcome.FAILURE -> exitCode?.takeIf { it != 0 } ?: 1
    }
}
