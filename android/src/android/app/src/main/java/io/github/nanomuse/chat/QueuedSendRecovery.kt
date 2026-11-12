package io.github.nanomuse.chat

import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext

/** 准备期间保留可撤回队列，接管后完整执行落盘与界面提交。 */
suspend fun <T, P, R> commitPreparedQueue(
    readQueue: () -> List<T>,
    id: (T) -> String,
    prepare: suspend (List<T>) -> P?,
    onCommitting: (List<T>) -> Unit,
    commit: suspend (List<T>, P) -> R,
    onRollback: (List<T>) -> Unit,
    dispatcher: CoroutineDispatcher = Dispatchers.Main.immediate,
): R? {
    var batch = withContext(dispatcher) { readQueue() }
    while (batch.isNotEmpty()) {
        val prepared = prepare(batch) ?: return null
        val outcome = withContext(dispatcher) {
            currentCoroutineContext().ensureActive()
            val currentIds = readQueue().map(id).toSet()
            val surviving = batch.filter { id(it) in currentIds }
            if (surviving.size != batch.size) {
                QueueCommitStep<T, R>(surviving, null, false)
            } else {
                // 接管与取消边界在同一主线程；落盘后必须完成可见提交，避免半提交重发。
                val result = withContext(NonCancellable) {
                    onCommitting(batch)
                    try {
                        commit(batch, prepared)
                    } catch (failure: Exception) {
                        onRollback(batch)
                        throw failure
                    }
                }
                QueueCommitStep<T, R>(emptyList(), result, true)
            }
        }
        currentCoroutineContext().ensureActive()
        if (outcome.isCommitted) return outcome.result
        batch = outcome.remaining
    }
    return null
}

/** 本轮重检结果，不把新入队条目混入已经准备的批次。 */
private data class QueueCommitStep<T, R>(
    val remaining: List<T>,
    val result: R?,
    val isCommitted: Boolean,
)

/** 保留发送失败原文和准备期间新输入的正文，重复恢复不追加同一前缀。 */
fun restoreFailedText(failed: String, current: String): String = when {
    failed.isEmpty() -> current
    current.isEmpty() || current == failed -> failed
    current.startsWith("$failed\n\n") -> current
    else -> "$failed\n\n$current"
}

/** 以稳定附件ID合并草稿，保留原附件携带的异步写入与重试对象。 */
fun <T> restoreFailedAttachments(
    failed: List<T>, current: List<T>, id: (T) -> String,
): List<T> = (failed + current).distinctBy(id)
