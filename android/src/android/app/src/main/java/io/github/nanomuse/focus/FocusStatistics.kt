package io.github.nanomuse.focus

import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId

/** 统计真实区间交集，不将跨午夜专注全部归入开始日。 */
object FocusStatistics {
    fun duration(spans:List<FocusSpan>,start:LocalDate,endExclusive:LocalDate,zone:ZoneId=ZoneId.systemDefault()):Long {
        val from=start.atStartOfDay(zone).toInstant().toEpochMilli()
        val until=endExclusive.atStartOfDay(zone).toInstant().toEpochMilli()
        return spans.sumOf { span -> (minOf(span.startedAt+span.durationMs,until)-maxOf(span.startedAt,from)).coerceAtLeast(0) }
    }
}
