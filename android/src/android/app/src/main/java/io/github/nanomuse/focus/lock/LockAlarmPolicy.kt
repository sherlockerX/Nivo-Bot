package io.github.nanomuse.focus.lock

/** 将固定会话投影到两个系统时钟，闹钟本身不负责判定完成。 */
object LockAlarmPolicy {
    /** 两个不同身份的结束闹钟与独立看门狗时间。 */
    data class Deadlines(val wallEnd: Long, val elapsedEnd: Long, val watchdogElapsed: Long)

    /** 到期不再下发闹钟；同次开机的墙钟调整只改变日历闹钟的投影。 */
    fun deadlines(run: LockRun, wall: Long, elapsed: Long, boot: Int): Deadlines? {
        val remaining = run.remaining(wall, elapsed, boot).milliseconds
        if (remaining <= 0) return null
        return Deadlines(Math.addExact(wall, remaining), Math.addExact(elapsed, remaining),
            Math.addExact(elapsed, minOf(60_000, remaining)))
    }
}
