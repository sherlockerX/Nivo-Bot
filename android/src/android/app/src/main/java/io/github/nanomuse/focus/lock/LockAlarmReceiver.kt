package io.github.nanomuse.focus.lock

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import io.github.nanomuse.account.AccountData
import kotlinx.coroutines.*

/** 闹钟和系统恢复广播使用同一账号边界，旧账号的PendingIntent不能接管新账号。 */
class LockAlarmReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == "io.github.nanomuse.focus.lock.ALARM" &&
            intent.getStringExtra("owner") != AccountData.key(context)) return
        val pending = goAsync()
        CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate).launch {
            try {
                LockAlarms.invalidate()
                val run = LockController.evaluate(context)
                if (run != null) LockGuardService.ensure(context)
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (_: Exception) { LockDiagnostics.record(context, LockDiagnosticAction.RESTORE) }
            finally { pending.finish() }
        }
    }
}
