package io.github.nanomuse.focus.lock

import android.content.Context
import android.os.SystemClock
import io.github.nanomuse.account.AccountData
import io.github.nanomuse.focus.FocusStore
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

/** 同一账号代次的不可变守护快照，不持有无障碍节点或用户输入。 */
data class LockSnapshot(val run: LockRun, val access: LockAccessPolicy.Context, val ownerEpoch: Long,
    /** 强制正计时：通知向上计时，不显示到上限的倒数。 */
    val countsUp: Boolean = false)

/** 进程内快照只用于快速判断，最终拦截仍须经过存储层到期结算。 */
object LockRuntime {
    private val mutableState = MutableStateFlow<LockSnapshot?>(null)
    val state: StateFlow<LockSnapshot?> = mutableState
    @Volatile var foregroundGeneration: Long = 0; private set
    @Volatile var foregroundPackage: String? = null; private set
    @Volatile var foregroundClass: String? = null; private set
    @Volatile var foregroundObservedWall: Long = 0; private set
    @Volatile var ownActivityClass: String? = null

    /** 每次拦截前读取真实单调钟，不缓存一秒前的剩余时间。 */
    fun remaining(context: Context, snapshot: LockSnapshot? = state.value): Long {
        val current = snapshot ?: return 0
        if (AccountData.epoch.value != current.ownerEpoch || AccountData.key(context) != current.run.ownerKey) return 0
        val boot = FocusStore.boot(context).takeIf { it >= 0 } ?: LockRun.PROCESS_BOOT_COUNT
        return current.run.remaining(System.currentTimeMillis(), SystemClock.elapsedRealtime(), boot).milliseconds
    }

    /** 存储结算完成后发布，旧会话的前台证据不能进入新会话。 */
    internal fun publish(snapshot: LockSnapshot?) {
        if (state.value?.run?.id != snapshot?.run?.id) {
            foregroundPackage = null; foregroundClass = null; foregroundObservedWall = 0
            foregroundGeneration++
        }
        mutableState.value = snapshot
    }

    /** 只在身份真正改变时增加代次，普通控件事件不能重置拉回节流。 */
    @Synchronized
    internal fun observeForeground(packageName: String?, className: String?, wall: Long) {
        if (foregroundPackage != packageName || foregroundClass != className) foregroundGeneration++
        foregroundPackage = packageName; foregroundClass = className; foregroundObservedWall = wall
    }
}
