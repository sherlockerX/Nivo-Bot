package io.github.nanomuse.routines

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch

/** 任务入口使用权威owner，避免依赖异步刷新的会话列表隐藏集合。 */
object ScheduledAccountPolicy {
    /** 过滤在分页之前完成，不将未知owner会话视为当前账号。 */
    fun <Row> visible(rows: List<Row>, ownedIds: Set<String>, limit: Int, id: (Row) -> String): List<Row> =
        rows.asSequence().filter { id(it) in ownedIds }.take(limit.coerceAtLeast(0)).toList()

    /** 同一账号退出后再登入也属于新空间，旧请求不得继续。 */
    fun isCurrent(owner: String, epoch: Long, currentOwner: String, currentEpoch: Long): Boolean =
        owner == currentOwner && epoch == currentEpoch

    /** 账号代次变化时取消实际工作并等待它清理，正常完成后不遗留观察协程。 */
    suspend fun <Value> untilChanged(epochs: StateFlow<Long>, expected: Long, block: suspend () -> Value): Value = coroutineScope {
        if (epochs.value != expected) throw CancellationException("ACCOUNT_CHANGED")
        val work = async(start = CoroutineStart.LAZY) { block() }
        val watcher = launch(start = CoroutineStart.UNDISPATCHED) {
            epochs.first { it != expected }
            work.cancel(CancellationException("ACCOUNT_CHANGED"))
        }
        try { work.await() }
        finally { watcher.cancel() }
    }
}
