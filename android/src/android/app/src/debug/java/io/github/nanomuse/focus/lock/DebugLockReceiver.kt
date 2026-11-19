package io.github.nanomuse.focus.lock

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import kotlinx.coroutines.*

/** 仅开发包存在的ADB安全通道，正式包没有此类和清单声明。 */
class DebugLockReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action !in setOf(ACTION_START, ACTION_STOP)) return
        val pending = goAsync()
        CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate).launch {
            try {
                if (intent.action == ACTION_START) LockController.startManual(context,
                    context.getString(com.openminis.app.R.string.nm_lock_title), null,
                    intent.getLongExtra("durationMs", 120_000L))
                else {
                    val store = LockStore.get(context)
                    store.transaction { store.finishInTransaction(LockRunStatus.EMERGENCY) }
                    LockController.evaluate(context)
                }
            } catch (_: Exception) { /* 调试拒绝不改变运行账本。 */ }
            finally { pending.finish() }
        }
    }

    companion object {
        const val ACTION_START = "io.github.nanomuse.focus.lock.DEBUG_START"
        const val ACTION_STOP = "io.github.nanomuse.focus.lock.DEBUG_STOP"
    }
}
