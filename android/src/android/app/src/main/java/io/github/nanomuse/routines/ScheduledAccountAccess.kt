package io.github.nanomuse.routines

import android.content.Context
import io.github.nanomuse.account.AccountData
import io.github.nanomuse.sync.ConversationSync
import kotlinx.coroutines.CancellationException

/** 单次派发捕获账号代次，短读写临界区与账号迁移串行。 */
data class ScheduledAccountAccess(val owner: String, val epoch: Long) {
    /** 账号往返也会使原派发失效，不能仅比较登录名。 */
    fun isCurrent(context: Context): Boolean = ScheduledAccountPolicy.isCurrent(
        owner, epoch, AccountData.key(context), AccountData.epoch.value)

    /** 任何空间变化都中断旧派发，不在新空间记录旧任务失败。 */
    fun requireCurrent(context: Context) {
        AccountData.requireAvailable()
        if (!isCurrent(context)) throw CancellationException("ACCOUNT_CHANGED")
    }

    /** 获取当前账号的权威会话集合，未知owner不获得访问权限。 */
    suspend fun ownedIds(context: Context): Set<String> {
        requireCurrent(context)
        return AccountData.sessionsOf(context, owner).toSet().also { requireCurrent(context) }
    }

    /** 此方法不能重入，也不能包裹模型运行或等待VM加载。 */
    suspend fun <Value> locked(context: Context, block: suspend () -> Value): Value =
        ConversationSync.exclusive {
            requireCurrent(context)
            block().also { requireCurrent(context) }
        }

    /** 无锁运行模型或脚本；迁移一开始就取消旧任务，并等待其取消清理。 */
    suspend fun <Value> running(context: Context, block: suspend () -> Value): Value {
        requireCurrent(context)
        return ScheduledAccountPolicy.untilChanged(AccountData.epoch, epoch, block)
    }

    companion object {
        /** 调用方在当前UI或派发入口捕获，不沿用其他账号创建的页面。 */
        fun capture(context: Context): ScheduledAccountAccess =
            ScheduledAccountAccess(AccountData.key(context), AccountData.epoch.value)
    }
}
