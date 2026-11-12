package io.github.nanomuse.account

import kotlin.coroutines.AbstractCoroutineContextElement
import kotlin.coroutines.CoroutineContext
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/** 短文件操作与迁移共用边界，不在文件门禁内等待协程、审批或数据库锁。 */
class AccountOperationGate {
    private val stateLock = Any()
    private val fileLock = Any()
    private val listeners = linkedMapOf<Any, () -> Unit>()
    private val mutableEpoch = MutableStateFlow(0L)
    @Volatile private var state = State(0L, true)

    /** 同一快照发布代次与可用性，避免观察到两者不一致。 */
    private data class State(val epoch: Long, val isAvailable: Boolean)

    /** 账号迁移开始与成功完成各递增一次。 */
    val epoch: StateFlow<Long> = mutableEpoch.asStateFlow()

    /** 固定发起操作时的账号代次。 */
    fun capture(): AccountOperation = AccountOperation(this, state.epoch)

    /** 先拒绝新操作并同步发出取消通知，再等待已进入的短文件操作结束。 */
    fun beginTransition() {
        val cancellations = synchronized(stateLock) {
            publish(State(state.epoch + 1, false))
            listeners.values.toList().also { listeners.clear() }
        }
        var failure: Throwable? = null
        cancellations.forEach { cancel ->
            runCatching(cancel).onFailure { if (failure == null) failure = it }
        }
        // 回调仅取消，不join；文件操作不得获取外层ConversationSync/迁移锁。
        synchronized(fileLock) { }
        failure?.let { throw it }
    }

    /** 完成迁移后发布新操作代次。 */
    fun finishTransition() = synchronized(stateLock) {
        publish(State(state.epoch + 1, true))
    }

    /** 失败的迁移在成功重试前保持关闭。 */
    fun requireAvailable() {
        check(state.isAvailable) { "The account space is unavailable; retry the account transition" }
    }

    internal fun isCurrent(expectedEpoch: Long): Boolean = state.let {
        it.isAvailable && it.epoch == expectedEpoch
    }

    internal fun requireCurrent(expectedEpoch: Long) {
        if (!isCurrent(expectedEpoch)) throw CancellationException("The account changed; reopen this conversation")
    }

    internal fun <T> files(expectedEpoch: Long, block: () -> T): T = synchronized(fileLock) {
        requireCurrent(expectedEpoch)
        block()
    }

    internal fun onInvalidated(expectedEpoch: Long, cancel: () -> Unit): AutoCloseable {
        val key = Any()
        val isRegistered = synchronized(stateLock) {
            if (isCurrent(expectedEpoch)) { listeners[key] = cancel; true } else false
        }
        if (!isRegistered) cancel()
        return AutoCloseable { synchronized(stateLock) { listeners.remove(key) }; Unit }
    }

    private fun publish(next: State) {
        state = next
        mutableEpoch.value = next.epoch
    }
}

/** 随协程传播的账号操作凭证。 */
class AccountOperation internal constructor(
    private val gate: AccountOperationGate,
    private val epoch: Long,
) : AbstractCoroutineContextElement(Key) {
    /** 账号操作的协程上下文键。 */
    companion object Key : CoroutineContext.Key<AccountOperation>

    /** 当前凭证是否仍可访问文件。 */
    fun isCurrent(): Boolean = gate.isCurrent(epoch)

    /** 拒绝失效的凭证。 */
    fun requireCurrent() = gate.requireCurrent(epoch)

    /** 在账号固定目录执行同步短操作。 */
    fun <T> files(block: () -> T): T = gate.files(epoch, block)

    /** 订阅凭证失效，不等待工作结束。 */
    fun onInvalidated(cancel: () -> Unit): AutoCloseable = gate.onInvalidated(epoch, cancel)
}
