package io.github.nanomuse.mosaic

import io.github.nanomuse.focus.FocusEntryLink
import io.github.nanomuse.todo.TodoEntryLink
import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.time.Clock
import java.time.Instant
import java.time.LocalDate

/** 验证真实命令协议、完整日记内容和日历状态边界。 */
class JigsawAccessTest {
    @Test fun should_echoInclusiveWindowAndEnergy_when_untilAliasUsed() = runBlocking {
        val result = command().execute(listOf("list", "--days", "2", "--until", "2026-10-27"))
        assertEquals(0, result.exitCode)
        val root = JSONObject(result.output)
        assertEquals("2026-10-26", root.getJSONObject("queried").getString("start"))
        assertEquals("2026-10-27", root.getJSONObject("queried").getString("end"))
        assertEquals(4, root.getJSONArray("days").getJSONObject(1).getInt("energy"))
        assertEquals(4, root.getJSONArray("days").getJSONObject(1).getJSONArray("records").getJSONObject(0).getInt("energy"))
    }
    // 手机设在上海时区；记录工具跟随手机时区。
    private val clock = Clock.fixed(Instant.parse("2026-10-27T17:00:00Z"), java.time.ZoneId.of("Asia/Shanghai"))
    private val date = LocalDate.parse("2026-10-27").toEpochDay()
    private val sentence = "日常的感悟\n".repeat(180)
    private val entry = MosaicEntry("e1", date, "America/Chicago", 1_798_927_200_000L,
        1_798_927_260_000L, null, null, sentence, "private-photo", "circle", .5f, .5f, 1f,
        mutationId = "m1", mood = 2)

    private fun command(snapshot: JigsawSnapshot = JigsawSnapshot(entries = listOf(entry))) =
        JigsawCommand(clock) { _, _ -> snapshot }

    @Test fun `calendar circles depend on saved records not habit marks and never mark future or loading`() {
        assertEquals(RecordDayStatus.RECORDED, recordDayStatus(date, date, 1))
        assertEquals(RecordDayStatus.MISSING, recordDayStatus(date - 1, date, 0))
        assertEquals(RecordDayStatus.MISSING, recordDayStatus(date, date, 0))
        assertEquals(RecordDayStatus.FUTURE, recordDayStatus(date + 1, date, 1))
        assertEquals(RecordDayStatus.LOADING, recordDayStatus(date, date, null))
    }

    @Test fun `acceptance command returns all seven dates complete text nulls and no picture information`() = runBlocking {
        val result = command().execute(listOf("list", "--start", "2026-10-21", "--end", "2026-10-27"))
        assertEquals(result.output, 0, result.exitCode)
        val output = JSONObject(result.output)
        val days = output.getJSONArray("days")
        assertEquals("Asia/Shanghai", output.getString("timezone"))
        assertEquals(7, days.length())
        assertEquals("2026-10-21", days.getJSONObject(0).getString("date"))
        assertTrue(days.getJSONObject(0).has("text"))
        assertTrue(days.getJSONObject(0).isNull("text"))
        assertTrue(days.getJSONObject(0).isNull("mood"))
        val last = days.getJSONObject(6)
        assertEquals(sentence, last.getString("text"))
        assertEquals(2, last.getInt("mood"))
        assertEquals(4, last.getInt("mood_score"))
        assertTrue(last.getString("created_at").endsWith("+08:00"))
        assertFalse(result.output.contains("private-photo"))
        assertFalse(result.output.contains("photo_paths"))
        assertFalse(result.output.contains("mediaPath"))
        assertFalse(result.output.contains("photo_count"))
    }

    @Test fun `get keeps each record with its mood sorted and excludes deleted entries`() = runBlocking {
        val old = entry.copy(id = "first", text = "较早", createdAt = entry.createdAt - 100, mood = null)
        val removed = entry.copy(id = "deleted", text = "已删除", deletedAt = 1L)
        val output = JSONObject(command(JigsawSnapshot(entries = listOf(entry, removed, old)))
            .execute(listOf("get", "--date=2026-10-27")).output)
        val day = output.getJSONArray("days").getJSONObject(0)
        val records = day.getJSONArray("records")
        assertEquals(2, records.length())
        assertEquals("first", records.getJSONObject(0).getString("id"))
        assertTrue(records.getJSONObject(0).isNull("mood"))
        assertEquals(sentence, records.getJSONObject(1).getString("text"))
        assertFalse(output.toString().contains("已删除"))
    }

    @Test fun `unmarked planned habits are false and skipped and paused histories are respected`() = runBlocking {
        val habits = listOf("read", "sleep", "paused", "walk").mapIndexed { i, id -> MosaicHabit(id, id, "circle", i, 0, 0) }
        val schedules = habits.map { MosaicHabitSchedule(it.id, date - 10, 127) } + MosaicHabitSchedule("paused", date, 0)
        val snapshot = JigsawSnapshot(habits = habits, schedules = schedules,
            marks = listOf(MosaicHabitDay("read", date, HabitState.DONE, 1), MosaicHabitDay("sleep", date, HabitState.SKIPPED, 1)))
        val day = JSONObject(command(snapshot).execute(listOf("get", "--date", "2026-10-27")).output)
            .getJSONArray("days").getJSONObject(0)
        val list = day.getJSONArray("habits")
        assertEquals(3, list.length())
        assertTrue(list.getJSONObject(0).getBoolean("done"))
        assertFalse(list.getJSONObject(1).getBoolean("done"))
        assertEquals("skipped", list.getJSONObject(1).getString("state"))
        assertFalse(list.getJSONObject(2).getBoolean("done"))
        assertTrue(list.getJSONObject(2).isNull("state"))
        assertTrue(day.isNull("text"))
    }

    @Test fun `year results page by complete days with an explicit next offset`() = runBlocking {
        val output = JSONObject(command().execute(listOf("list", "--start", "2024-01-01", "--end", "2024-12-31", "--limit", "31")).output)
        assertEquals(31, output.getJSONArray("days").length())
        assertTrue(output.getBoolean("has_more"))
        assertEquals(31, output.getInt("next_offset"))
        val next = JSONObject(command().execute(listOf("list", "--start", "2024-01-01", "--end", "2024-12-31", "--limit", "31", "--offset", "31")).output)
        assertEquals("2024-02-01", next.getJSONArray("days").getJSONObject(0).getString("date"))
    }

    @Test fun `default dates and timestamps follow the phone time zone`() = runBlocking {
        val shanghai = JSONObject(command().execute(listOf("list", "--days", "1")).output)
        assertEquals("2026-10-28", shanghai.getString("start"))
        assertEquals("Asia/Shanghai", shanghai.getString("timezone"))
        // 同一时刻在芝加哥还是10月27日中午，记录工具按手机所在时区给出今天和时间戳。
        val chicagoClock = Clock.fixed(Instant.parse("2026-10-27T17:00:00Z"), java.time.ZoneId.of("America/Chicago"))
        val chicago = JSONObject(JigsawCommand(chicagoClock) { _, _ -> JigsawSnapshot(entries = listOf(entry)) }
            .execute(listOf("list", "--days", "1")).output)
        assertEquals("2026-10-27", chicago.getString("start"))
        assertEquals("America/Chicago", chicago.getString("timezone"))
        val createdAt = chicago.getJSONArray("days").getJSONObject(0).getJSONArray("records").getJSONObject(0).getString("created_at")
        assertTrue(createdAt, createdAt.endsWith("-05:00") || createdAt.endsWith("-06:00"))
    }

    @Test fun `bad dates missing values unknown arguments and writes fail before touching data`() = runBlocking {
        var reads = 0
        val command = JigsawCommand(clock) { _, _ -> reads++; JigsawSnapshot() }
        val invalid = listOf(
            listOf("list", "--start", "2026-02-30"), listOf("list", "--start"),
            listOf("list", "--start", "2026-11-01", "--end", "2026-10-01"),
            listOf("list", "--limit", "0"), listOf("list", "--offset", "-1"),
            listOf("list", "--unknown", "x"), listOf("delete", "--date", "2026-10-27"),
            listOf("export", "--out", "/tmp/jigsaw.json"), listOf("get"),
        )
        for (args in invalid) assertEquals(args.toString(), 2, command.execute(args).exitCode)
        assertEquals(0, reads)
    }

    @Test fun `markdown export retains full text and stats cover the entire range`() = runBlocking {
        val markdown = command().execute(listOf("export", "--start", "2026-10-27", "--end", "2026-10-27", "--format", "md"))
        assertEquals(0, markdown.exitCode)
        assertTrue(markdown.output.contains(sentence))
        val stats = JSONObject(command().execute(listOf("stats", "--start", "2026-10-21", "--end", "2026-10-27")).output).getJSONObject("stats")
        assertEquals(7, stats.getInt("days"))
        assertEquals(1, stats.getInt("recorded_days"))
        assertEquals(6, stats.getInt("missing_days"))
        assertEquals(4.0, stats.getDouble("average_energy"), 0.0)
    }
    @Test fun `cleared daily mood stays null and an earlier entry never fills a later blank mood`() = runBlocking {
        val snapshot = JigsawSnapshot(entries = listOf(entry), days = listOf(MosaicDayInfo(date, mood = null, updatedAt = 2)))
        val day = JSONObject(command(snapshot).execute(listOf("get", "--date", "2026-10-27")).output)
            .getJSONArray("days").getJSONObject(0)
        assertTrue(day.isNull("mood"))
        assertEquals(2, day.getJSONArray("records").getJSONObject(0).getInt("mood"))
        val later = entry.copy(id = "later", createdAt = entry.createdAt + 100, mood = null)
        val second = JSONObject(command(JigsawSnapshot(entries = listOf(entry, later)))
            .execute(listOf("get", "--date", "2026-10-27")).output).getJSONArray("days").getJSONObject(0)
        assertTrue(second.isNull("mood"))
    }

    @Test fun `future days are counted separately from missed diary days`() = runBlocking {
        val stats = JSONObject(command().execute(listOf("stats", "--start", "2026-10-27", "--end", "2026-10-31")).output)
            .getJSONObject("stats")
        assertEquals(1, stats.getInt("recorded_days"))
        assertEquals(1, stats.getInt("missing_days"))
        assertEquals(3, stats.getInt("future_days"))
    }

    @Test fun `large results fail explicitly while statistics still work without emitting the text`() = runBlocking {
        val large = command(JigsawSnapshot(entries = listOf(entry.copy(text = "文".repeat(600_000)))))
        assertEquals(2, large.execute(listOf("get", "--date", "2026-10-27")).exitCode)
        val result = large.execute(listOf("stats", "--start", "2026-10-27", "--end", "2026-10-27"))
        assertEquals(0, result.exitCode)
        assertFalse(result.output.contains("文"))
    }

    @Test fun `paging only asks the database for the requested whole days`() = runBlocking {
        var requested: Pair<Long, Long>? = null
        val command = JigsawCommand(clock) { start, end -> requested = start to end; JigsawSnapshot() }
        command.execute(listOf("list", "--start", "2026-01-01", "--end", "2026-12-31", "--limit", "31", "--offset", "31"))
        assertEquals(LocalDate.parse("2026-02-01").toEpochDay() to LocalDate.parse("2026-03-04").toEpochDay(), requested)
    }

    @Test fun should_preserveAssociationSnapshots_withoutInferringCompletion() = runBlocking {
        val snapshot = JigsawSnapshot(entries = listOf(entry),
            todoLinks = listOf(TodoEntryLink("owner", entry.id, "task", "保存时任务名", "doing", 100L)),
            focusLinks = listOf(FocusEntryLink("owner", entry.id, "focus", "保存时专注名", 10L, 90L, 60L)))
        val output = JSONObject(command(snapshot).execute(listOf("get", "--date", "2026-10-27")).output)
        assertEquals("device_local", output.getString("scope"))
        assertEquals("current_account", output.getString("linked_records_scope"))
        assertEquals("saved_snapshots_no_completion_inference", output.getString("association_semantics"))
        val record = output.getJSONArray("days").getJSONObject(0).getJSONArray("records").getJSONObject(0)
        val task = record.getJSONArray("todo_links").getJSONObject(0)
        assertEquals("task", task.getString("task_id"))
        assertEquals("保存时任务名", task.getString("title_snapshot"))
        assertEquals("doing", task.getString("status_snapshot"))
        assertEquals(100L, task.getLong("linked_at_ms"))
        assertFalse(task.has("done"))
        assertFalse(task.has("completed"))
        assertFalse(task.has("ownerKey"))
        val focus = record.getJSONArray("focus_links").getJSONObject(0)
        assertEquals("focus", focus.getString("session_id"))
        assertEquals("保存时专注名", focus.getString("title_snapshot"))
        assertEquals(10L, focus.getLong("started_at_ms"))
        assertEquals(90L, focus.getLong("ended_at_ms"))
        assertEquals(60L, focus.getLong("duration_ms"))
        assertFalse(focus.has("completed"))
        assertFalse(focus.has("ownerKey"))
        // 关联的专注时段就是这条记录的实测用时。
        assertEquals("focused_activity", record.getString("kind"))
        assertEquals(60L, record.getLong("measured_focus_ms"))
    }

    @Test fun should_emitOnlyMatchingLinks_andKeepDefaultEmptySnapshotsCompatible() = runBlocking {
        val snapshot = JigsawSnapshot(entries = listOf(entry),
            todoLinks = listOf(TodoEntryLink("owner", "unrequested", "task", "范围外任务", "done", 100L)),
            focusLinks = listOf(FocusEntryLink("owner", "unrequested", "focus", "范围外专注", 10L, 90L, 60L)))
        val result = command(snapshot).execute(listOf("get", "--date", "2026-10-27"))
        val record = JSONObject(result.output).getJSONArray("days").getJSONObject(0)
            .getJSONArray("records").getJSONObject(0)
        assertEquals(0, record.getJSONArray("todo_links").length())
        assertEquals(0, record.getJSONArray("focus_links").length())
        assertEquals("daily_note", record.getString("kind"))
        assertEquals(0L, record.getLong("measured_focus_ms"))
        assertFalse(result.output.contains("范围外"))
        val legacy = JSONObject(command().execute(listOf("get", "--date", "2026-10-27")).output)
            .getJSONArray("days").getJSONObject(0).getJSONArray("records").getJSONObject(0)
        assertEquals(0, legacy.getJSONArray("todo_links").length())
        assertEquals(0, legacy.getJSONArray("focus_links").length())
    }

    @Test fun should_includeAssociationSnapshotsInMarkdown_withoutChangingOriginalText() = runBlocking {
        val snapshot = JigsawSnapshot(entries = listOf(entry),
            todoLinks = listOf(TodoEntryLink("owner", entry.id, "task", "保存时任务名", "doing", 100L)),
            focusLinks = listOf(FocusEntryLink("owner", entry.id, "focus", "保存时专注名", 10L, 90L, 60L)))
        val result = command(snapshot).execute(listOf("get", "--date", "2026-10-27", "--format", "md"))
        assertEquals(0, result.exitCode)
        assertTrue(result.output.contains(sentence))
        assertTrue(result.output.contains("device_local"))
        assertTrue(result.output.contains("current_account"))
        assertTrue(result.output.contains("保存时任务名"))
        assertTrue(result.output.contains("status_snapshot: doing"))
        assertTrue(result.output.contains("保存时专注名"))
        assertTrue(result.output.contains("duration_ms: 60"))
        assertTrue(result.output.contains("Time spent (measured focus)"))
        assertTrue(result.output.contains("never use it as time spent"))
        assertFalse(result.output.contains("[x]"))
    }

}
