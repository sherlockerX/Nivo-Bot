package io.github.nanomuse.sandbox

import org.junit.Assert.*
import org.junit.Test

/** 缺失终点不产生1970年，时长解析拒绝错误和溢出。 */
class CalendarEventEndTest {
    @Test fun should_keepExplicitEnd_when_present() { assertEquals(2000L, CalendarEventEnd.resolve(1000, 2000, "PT1H")) }
    @Test fun should_returnNull_when_endUnknown() { assertNull(CalendarEventEnd.resolve(1000, null, null)) }
    @Test fun should_resolveDuration_when_noEnd() {
        assertEquals(3_601_000L, CalendarEventEnd.resolve(1000, null, "PT1H"))
        assertEquals(86_401_000L, CalendarEventEnd.resolve(1000, null, "P1D"))
        assertEquals(1_209_601_000L, CalendarEventEnd.resolve(1000, null, "P2W"))
    }
    @Test fun should_rejectInvalidOrOverflow_when_durationBroken() {
        listOf("", "1 hour", "-PT1H", "P99999999999999999W").forEach { assertNull(CalendarEventEnd.resolve(1000, null, it)) }
        assertNull(CalendarEventEnd.resolve(Long.MAX_VALUE, null, "PT1H"))
    }
    @Test fun should_allowEpochZero_when_reliableEnd() { assertEquals(0L, CalendarEventEnd.resolve(-1000, 0, null)) }
}
