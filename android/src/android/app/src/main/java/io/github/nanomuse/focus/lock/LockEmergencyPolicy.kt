package io.github.nanomuse.focus.lock

/** 等待状态只保存单调时钟和剩余量，墙钟不是紧急退出的授权证据。 */
data class LockEmergencyWait(val runId: String, val remainingMs: Long, val checkpointElapsed: Long, val bootCount: Int)

/** 独立于Android的十分钟等待契约。 */
object LockEmergencyPolicy {
    const val WAIT_MS=600_000L
    /** 首次申请创建固定等待，宿主负责复用已有申请。 */
    fun begin(runId:String,elapsed:Long,boot:Int)=LockEmergencyWait(runId,WAIT_MS,elapsed,boot)
    /** 重启或未知启动时保留检查点，不用可修改的墙钟缩短等待。 */
    fun remaining(wait:LockEmergencyWait,elapsed:Long,boot:Int):Long {
        val sameBoot=(boot>=0 || boot==LockRun.PROCESS_BOOT_COUNT) && wait.bootCount==boot
        if(!sameBoot || elapsed<wait.checkpointElapsed) return wait.remainingMs
        return (wait.remainingMs-(elapsed-wait.checkpointElapsed)).coerceAtLeast(0)
    }
    /** 保存新的单调基准。 */
    fun checkpoint(wait:LockEmergencyWait,elapsed:Long,boot:Int)=wait.copy(
        remainingMs=remaining(wait,elapsed,boot),checkpointElapsed=elapsed,bootCount=boot)
    /** 只有相同会话且完整等待后才能进入第二次确认。 */
    fun canConfirm(wait:LockEmergencyWait,runId:String,elapsed:Long,boot:Int)=
        wait.runId==runId && remaining(wait,elapsed,boot)==0L
}
