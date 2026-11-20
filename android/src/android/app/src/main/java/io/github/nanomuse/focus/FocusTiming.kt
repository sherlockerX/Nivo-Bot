package io.github.nanomuse.focus

/** 单调时间不受校时影响，到时回调延迟也不能超过预定时长。 */
object FocusTiming {
    fun delta(start: Long, now: Long, sameBoot: Boolean, remaining: Long): Long =
        if (!sameBoot || start < 0 || now < start) 0 else (now - start).coerceAtMost(remaining.coerceAtLeast(0))

    /** 已结算截止优先，暂停沿用停止时刻；墙钟回拨不能构造结束早于开始的区间。 */
    fun endedAt(previous: FocusSession, settled: FocusSession, now: Long): Long =
        settled.endedAt ?: (if (previous.status == "paused") previous.updatedAt else now)
            .coerceAtLeast(previous.startedAt)
}
