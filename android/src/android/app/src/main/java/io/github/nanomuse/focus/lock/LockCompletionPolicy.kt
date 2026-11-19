package io.github.nanomuse.focus.lock

/** 将完成通知的历史筛选从Android通知发送中分离。 */
object LockCompletionPolicy {
    /** 历史恢复仅补发近期完成，实际状态转换另由运行身份提供。 */
    fun shouldNotify(status: LockRunStatus, runId: String, endedAt: Long?, now: Long,
        previousRunId: String?): Boolean = status == LockRunStatus.COMPLETED &&
        endedAt != null && (runId == previousRunId || now - endedAt in 0..300_000)
}
