package io.github.nanomuse.routines

import com.openminis.app.scheduled.ScheduledTask
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

/** 调度元数据及执行参数不能在保存与恢复时丢失。 */
class ScheduledLifecycleTest {
    private fun task() = ScheduledTask(label = "fixture", timeOfDayHour = 6, timeOfDayMinute = 10,
        repeatMode = com.openminis.app.scheduled.ScheduledRepeatMode.DAILY, prompt = "offline")

    @Test fun should_preserveExecutionOptions_when_loadingTaskJson() {
        val input = task().toJson().put("scriptArgs", org.json.JSONArray(listOf("a b; echo bad", "am")))
            .put("requireOutput", true).put("logStdout", true).put("unknownRuns", 3)
            .put("lastOutcome", "unknown").put("countingSinceMs", 123L).put("origin", "user")
        val restored = ScheduledTask.fromJson(input).toJson()
        assertEquals(input.getJSONArray("scriptArgs").toString(), restored.optJSONArray("scriptArgs")?.toString())
        assertTrue(restored.optBoolean("requireOutput"))
        assertEquals(3, restored.optInt("unknownRuns"))
        assertEquals("unknown", restored.optString("lastOutcome"))
        assertEquals(123L, restored.optLong("countingSinceMs"))
    }

    @Test fun should_keepAbsentOutcomeUnknown_when_loadingLegacyTask() {
        val legacy = task().toJson()
        legacy.remove("lastOutcome")
        assertEquals("unknown", ScheduledTask.fromJson(legacy).toJson().optString("lastOutcome"))
    }
}
