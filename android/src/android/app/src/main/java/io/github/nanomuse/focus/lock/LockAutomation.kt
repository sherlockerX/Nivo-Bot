package io.github.nanomuse.focus.lock

import android.content.Context
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking

/** 仅由屏幕操作的后台工作线程调用，数据库检查覆盖进程刚恢复时尚无快照的间隙。 */
object LockAutomation {
    /** 每个实际动作前检查持久会话，已到期时先由Store结算。 */
    fun requireAllowed(context:Context) {
        val run=runBlocking(Dispatchers.IO) { LockStore.get(context).active() }
        if(run!=null) throw FocusLockedException()
    }
    /** 工具入口将固定错误码直接返回给模型。 */
    fun isBlocked(context:Context):Boolean=try { requireAllowed(context);false }
        catch(_:FocusLockedException) { true }
}
