package io.github.nanomuse.focus

import org.junit.Assert.*
import org.junit.Test

/** 核实锁屏计时、重启和到时封顶。 */
class FocusTimingTest {
    @Test fun should_countMonotonicTime_evenWhenScreenIsClosed() { assertEquals(5000L, FocusTiming.delta(1000, 6000, true, 9000)) }
    @Test fun should_capAtTarget_whenAlarmIsLate() { assertEquals(3000L, FocusTiming.delta(1000, 9000, true, 3000)) }
    @Test fun should_notInventOfflineTime_afterReboot() { assertEquals(0L, FocusTiming.delta(1000, 9000, false, 9000)) }
    @Test fun should_rejectNegativeElapsedTime() { assertEquals(0L, FocusTiming.delta(9000, 1000, true, 9000)) }
}
