package io.github.nanomuse.routines

import kotlinx.coroutines.*
import kotlin.coroutines.CoroutineContext
import kotlin.coroutines.EmptyCoroutineContext

/** 一轮任务的稳定父句柄，覆盖准备、重跑和执行，不随UI的streamJob切换。 */
class ScheduledChatRun(parent: Job?) {
    val job: CompletableJob = Job(parent)
    var hasStarted: Boolean = false
        private set

    /** 所有本轮准备与执行协程都加入同一父Job。 */
    fun launch(scope: CoroutineScope, context: CoroutineContext = EmptyCoroutineContext,
        block: suspend CoroutineScope.() -> Unit): Job {
        hasStarted = true
        return scope.launch(context + job, block = block)
    }

    /** 派发返回后不再保留空父Job，仍等待已有子协程及其后续子工作结束。 */
    fun seal() { job.complete() }
}
