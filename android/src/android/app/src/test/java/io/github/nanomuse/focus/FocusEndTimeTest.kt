package io.github.nanomuse.focus

import org.junit.Assert.assertEquals
import org.junit.Test

/** 结束时刻与单调计量分开，暂停和墙钟回拨不能改写已停止的事实。 */
class FocusEndTimeTest {
    @Test fun should_keepPauseTime_when_wallClockMovesBeforeStart() {
        val paused = session().copy(status = "paused", updatedAt = 12_000)
        assertEquals(12_000L, FocusTiming.endedAt(paused, paused, 9_000))
    }

    @Test fun should_keepPauseTime_when_forcedFocusStartsNextDay() {
        val paused = session().copy(status = "paused", updatedAt = 12_000)
        assertEquals(12_000L, FocusTiming.endedAt(paused, paused, 90_000_000))
    }

    @Test fun should_keepNaturalDeadline_when_callbackIsLate() {
        val running = session()
        assertEquals(70_000L, FocusTiming.endedAt(running,
            running.copy(status = "finished", endedAt = 70_000), 90_000))
    }

    @Test fun should_notEndBeforeStart_when_runningWallClockMovesBack() {
        val running = session()
        assertEquals(10_000L, FocusTiming.endedAt(running, running.copy(status = "paused"), 9_000))
    }

    private fun session() = FocusSession(ownerKey = "owner", id = "session", title = "阅读",
        taskId = null, groupName = "", tagsJson = "[]",
        mode = "pomodoro", targetMs = 60_000, startedAt = 10_000, updatedAt = 10_000,
        runningWall = 10_000, runningElapsed = 100, bootCount = 1)
}
