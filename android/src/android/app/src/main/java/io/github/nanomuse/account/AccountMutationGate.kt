package io.github.nanomuse.account

import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.flow.StateFlow

/** 新会话登记与账号身份迁移共用边界，等待期间改变身份的请求必须重试。 */
class AccountMutationGate {
    /** 普通聊天的固定目录与迁移共享账号操作边界。 */
    val operations = AccountOperationGate()
    private val mutex = Mutex()
    /** 只记录账号迁移的开始和完成，不受教练内存缓存刷新影响。 */
    val epoch: StateFlow<Long> = operations.epoch

    /** 捕获发起时的归属，成功落盘前禁止账号迁移插入。 */
    suspend fun <T> create(owner: () -> String, block: suspend (String) -> T): T {
        val expectedGeneration = epoch.value
        val expected = owner()
        return mutex.withLock {
            requireAvailable()
            currentCoroutineContext()[AccountOperation]?.requireCurrent()
            check(epoch.value == expectedGeneration && owner() == expected) { "The account changed; retry in the current account" }
            block(expected)
        }
    }

    /** 调用方负责在同一边界内完成身份、文件与所有权表变更。 */
    suspend fun <T> exclusive(block: suspend () -> T): T = mutex.withLock {
        requireAvailable()
        currentCoroutineContext()[AccountOperation]?.requireCurrent()
        block()
    }

    /** 已持同步外层锁的导入路径也必须拒绝失败后尚未恢复的空间。 */
    fun requireAvailable() {
        operations.requireAvailable()
    }

    /** 失败的迁移保持关闭，只有一次完整迁移才能重新允许创建会话。 */
    suspend fun <T> transition(block: suspend () -> T): T = mutex.withLock {
        operations.beginTransition()
        val result = block()
        operations.finishTransition()
        result
    }
}
