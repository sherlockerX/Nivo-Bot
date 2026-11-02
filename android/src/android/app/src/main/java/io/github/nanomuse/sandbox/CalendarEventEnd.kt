package io.github.nanomuse.sandbox

/** 解析日历的显式终点或RFC5545时长，不把缺失值格式化成1970年。 */
object CalendarEventEnd {
    /** 无有效终点或时长时返回空值，不猜测持续时间。 */
    fun resolve(start: Long, end: Long?, duration: String?): Long? {
        if (end != null && end >= start) return end
        if (duration.isNullOrBlank()) return null
        return runCatching {
            val normalized = if (Regex("P[0-9]+W").matches(duration)) {
                "P${Math.multiplyExact(duration.drop(1).dropLast(1).toLong(), 7)}D"
            } else duration
            val elapsed = java.time.Duration.parse(normalized).toMillis()
            if (elapsed < 0) null else Math.addExact(start, elapsed)
        }.getOrNull()
    }
}
