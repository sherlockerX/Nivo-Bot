package io.github.nanomuse.focus.lock

import android.content.Context
import android.os.SystemClock
import io.github.nanomuse.focus.FocusStore
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject

/** 等待申请持久保存，最终确认仍在账号锁和Room事务中检查当前运行身份。 */
class LockEmergency(private val context:Context,private val store:LockStore) {
    private val preferences=context.getSharedPreferences(LockSettings.fileName(store.ownerKey),Context.MODE_PRIVATE)
    private var processWait:LockEmergencyWait?=null

    /** 读取会话自己的等待，其他会话的旧状态不会成为退出授权。 */
    suspend fun state(runId:String):LockEmergencyWait?=withContext(Dispatchers.IO) { store.transaction {
        read(runId)?.let { settle(it,false) }
    } }
    /** 重复长按不会重置等待，也不会减少剩余时间。 */
    suspend fun begin(runId:String):LockEmergencyWait=withContext(Dispatchers.IO) { store.transaction {
        requireActive(runId)
        read(runId)?.let { return@transaction settle(it,true) }
        val wait=LockEmergencyPolicy.begin(runId,SystemClock.elapsedRealtime(),boot())
        save(wait);wait
    } }
    /** 等待结束后仍需用户再次确认，界面隐藏按钮不能替代此处校验。 */
    suspend fun confirm(runId:String)=withContext(Dispatchers.IO) {
        store.transaction {
            requireActive(runId)
            val wait=read(runId)?.let { settle(it,true) } ?: error("emergency_not_requested")
            check(LockEmergencyPolicy.canConfirm(wait,runId,SystemClock.elapsedRealtime(),boot())) { "emergency_wait_required" }
            store.finishInTransaction(LockRunStatus.EMERGENCY)
            preferences.edit().remove("emergency-wait").commit();processWait=null
        }
        LockDiagnostics.record(context,LockDiagnosticAction.EMERGENCY)
        LockController.evaluate(context)
    }

    private suspend fun requireActive(runId:String) {
        check(LockSettings(context,store).emergencyEnabled()) { "emergency_disabled" }
        check(store.checkpointInTransaction()?.id==runId) { "lock_not_active" }
    }
    private fun boot():Int=FocusStore.boot(context).takeIf { it>=0 } ?: LockRun.PROCESS_BOOT_COUNT
    private fun read(runId:String):LockEmergencyWait? {
        val cached=processWait
        if(cached?.runId==runId) return cached
        val json=preferences.getString("emergency-wait",null)?.let { runCatching { JSONObject(it) }.getOrNull() } ?: return null
        if(json.optString("run")!=runId) return null
        val remaining=json.getLong("remaining").also { require(it in 0..LockEmergencyPolicy.WAIT_MS) }
        return LockEmergencyWait(runId,remaining,json.getLong("elapsed"),json.getInt("boot")).also { processWait=it }
    }
    private fun settle(wait:LockEmergencyWait,force:Boolean):LockEmergencyWait {
        val elapsed=SystemClock.elapsedRealtime();val next=LockEmergencyPolicy.checkpoint(wait,elapsed,boot())
        if(force || wait.bootCount!=boot() || elapsed-wait.checkpointElapsed>=15_000 || next.remainingMs==0L) save(next)
        return next
    }
    private fun save(wait:LockEmergencyWait) {
        val persisted=wait.copy(bootCount=wait.bootCount.takeIf { it>=0 } ?: -1)
        check(preferences.edit().putString("emergency-wait",JSONObject().put("run",wait.runId)
            .put("remaining",persisted.remainingMs).put("elapsed",persisted.checkpointElapsed)
            .put("boot",persisted.bootCount).toString()).commit()) { "emergency_write_failed" }
        processWait=wait
    }
}
