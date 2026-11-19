package io.github.nanomuse.focus.lock

import java.util.concurrent.ConcurrentHashMap

/** 当前进程的临时计时基准；UUID运行身份不复用，基准不随事务回滚或完成删除。 */
class LockProcessClocks {
    private val anchors = ConcurrentHashMap<Pair<String, String>, Anchor>()

    /** 只保存计算所需的首次单调基准，不缓存可变计划、白名单或结束状态。 */
    private data class Anchor(val remainingMs: Long, val elapsed: Long)

    /** 记录当前进程首次建立的临时检查点。 */
    fun remember(run: LockRun) {
        if (run.bootCount != LockRun.PROCESS_BOOT_COUNT) return
        anchors.putIfAbsent(
            run.ownerKey to run.id,
            Anchor(run.checkpointRemainingMs, run.checkpointElapsed)
        )
    }

    /** 仅补充未知启动记录的检查点，最新生命周期和配置字段保持持久值。 */
    fun restore(persisted: LockRun): LockRun {
        if (persisted.bootCount >= 0) return persisted
        val anchor = anchors[persisted.ownerKey to persisted.id] ?: return persisted
        return persisted.copy(
            checkpointRemainingMs = anchor.remainingMs,
            checkpointElapsed = anchor.elapsed,
            bootCount = LockRun.PROCESS_BOOT_COUNT
        )
    }
}
