package io.github.nanomuse.focus

import org.junit.Assert.*
import org.junit.Test
import java.time.*

/** 按时区的午夜边界截取真实区间，跨日和夏令时不按固定24小时猜算。 */
class FocusStatisticsTest {
    @Test fun should_splitAcrossMidnight() {
        val zone=ZoneId.of("Asia/Shanghai");val day=LocalDate.of(2026,11,11)
        val start=day.atTime(23,50).atZone(zone).toInstant().toEpochMilli()
        val span=FocusSpan("owner","id","session",start,30*60_000)
        assertEquals(10*60_000L,FocusStatistics.duration(listOf(span),day,day.plusDays(1),zone))
        assertEquals(20*60_000L,FocusStatistics.duration(listOf(span),day.plusDays(1),day.plusDays(2),zone))
    }
    @Test fun should_useRealDstDayBoundaries() {
        val zone=ZoneId.of("America/Chicago");val day=LocalDate.of(2026,3,8)
        val start=day.atStartOfDay(zone).toInstant().toEpochMilli()
        val span=FocusSpan("owner","id","session",start,24*60*60_000L)
        assertEquals(23*60*60_000L,FocusStatistics.duration(listOf(span),day,day.plusDays(1),zone))
    }
}
