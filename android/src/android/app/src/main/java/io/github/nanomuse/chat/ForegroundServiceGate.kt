package io.github.nanomuse.chat

/**
 * 前台服务的启动、提升和停止记录。
 *
 * `startForegroundService()`之后、服务调用`startForeground()`之前停止服务，系统会让应用崩溃。
 * 因此每次启动领一个序号，服务在`onStartCommand`里提升后交还；还有序号没交还时，停止请求只记下来，
 * 由服务在提升后自行停止。启动和停止都在同一把锁里发出，不会有新的启动插在判断与停止之间。
 */
class ForegroundServiceGate {
    private var issued = 0L
    private var promoted = 0L
    private var isStopRequested = false

    /** 领取序号并启动；[start]返回假表示系统没有接受，序号作废。新的启动会撤销还没执行的停止。 */
    @Synchronized
    fun start(start: (sequence: Long) -> Boolean): Boolean {
        val sequence = ++issued
        isStopRequested = false
        var isAccepted = false
        try {
            isAccepted = start(sequence)
        } finally {
            if (!isAccepted) issued = sequence - 1
        }
        return isAccepted
    }

    /** 没有等待提升的启动时立即停止，否则等服务提升后再停。 */
    @Synchronized
    fun stop(stop: () -> Unit) {
        if (issued > promoted) isStopRequested = true else stop()
    }

    /** 服务处理完一次启动后调用（系统拒绝提升也算处理完）；有等待中的停止且没有更新的启动时执行[stop]。 */
    @Synchronized
    fun promoted(sequence: Long, stop: () -> Unit) {
        promoted = maxOf(promoted, sequence)
        if (!isStopRequested || issued > promoted) return
        isStopRequested = false
        stop()
    }
}
