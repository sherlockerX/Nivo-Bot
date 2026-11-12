package io.github.nanomuse.media

import java.util.concurrent.atomic.AtomicBoolean
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.suspendCancellableCoroutine

/** 将异步资源的清理权移交给宿主，重复关闭不会再次释放。 */
class OwnedResource<T>(val value: T, private val release: (T) -> Unit) : AutoCloseable {
    private val isClosed = AtomicBoolean(false)

    /** 准备失败、取消或宿主退出均可调用，资源只释放一次。 */
    override fun close() {
        if (isClosed.compareAndSet(false, true)) release(value)
    }
}

/** 等待回调式准备完成，取消和任何准备失败都会关闭已创建资源。 */
suspend fun <T> awaitPreparedResource(
    create: () -> T,
    release: (T) -> Unit,
    start: (T, () -> Unit, (Throwable) -> Unit) -> Unit,
): OwnedResource<T> = suspendCancellableCoroutine { continuation ->
    val owned = OwnedResource(create(), release)
    val hasFinished = AtomicBoolean(false)
    continuation.invokeOnCancellation { owned.close() }
    val fail: (Throwable) -> Unit = { failure ->
        if (hasFinished.compareAndSet(false, true)) {
            owned.close()
            if (continuation.isActive) continuation.resumeWithException(failure)
        }
    }
    try {
        if (continuation.isActive) start(owned.value, {
            if (hasFinished.compareAndSet(false, true)) {
                continuation.resume(owned) { _, value, _ -> value.close() }
            }
        }, fail)
    } catch (failure: Throwable) {
        fail(failure)
    }
}
