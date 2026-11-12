package io.github.nanomuse.focus

/** 单调时间不受校时影响，到时回调延迟也不能超过预定时长。 */
object FocusTiming {
    fun delta(start: Long, now: Long, sameBoot: Boolean, remaining: Long): Long =
        if (!sameBoot || start < 0 || now < start) 0 else (now - start).coerceAtMost(remaining.coerceAtLeast(0))
}
