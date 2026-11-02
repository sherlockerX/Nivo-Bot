package io.github.nanomuse.mosaic

import org.json.JSONArray
import org.json.JSONObject
import java.time.Instant
import java.time.LocalDate
import java.time.format.DateTimeFormatter

/** 将数据库快照转成可复盘的文本，不获取或序列化任何图片信息。 */
internal class JigsawOutput(private val query: JigsawQuery, snapshot: JigsawSnapshot) {
    private val range = if (query.command == "stats") query.range else query.page
    private val entries = snapshot.entries.filter { it.deletedAt == null && it.day in range.startDay until range.endDay }
        .sortedWith(compareBy<MosaicEntry> { it.day }.thenBy { it.createdAt }.thenBy { it.id })
    private val byDay = entries.groupBy { it.day }
    private val days = snapshot.days.associateBy { it.day }
    private val marks = snapshot.marks.associateBy { it.habitId to it.day }
    private val hasConfiguredHabits = snapshot.habits.isNotEmpty()
    private val period = MosaicPeriod(range, emptyList(), snapshot.marks, snapshot.days,
        snapshot.habits.sortedWith(compareBy<MosaicHabit> { it.sortOrder }.thenBy { it.id }),
        snapshot.schedules.sortedWith(compareBy<MosaicHabitSchedule> { it.habitId }.thenBy { it.fromDay }))
    private val plannedByDay = (range.startDay until range.endDay).associateWith { period.planned(it) }

    init {
        // 正文会同时出现在每日摘要和逐条记录中，先限制源数据，避免构建大 JSON 时占满堆。
        if (query.command != "stats") {
            require(entries.sumOf { it.text.length.toLong() } <= 500_000L && plannedByDay.values.sumOf { it.size } <= 10_000) {
                "Result is too large. Use a smaller date range or --limit; no text was truncated."
            }
        }
    }

    /** 生成 JSON 或 Markdown，正文始终原样保留。 */
    fun render(): String {
        val root = JSONObject().put("timezone", JigsawQuery.ZONE.id)
            .put("start", query.range.start.toString()).put("end", query.range.endExclusive.minusDays(1).toString())
            .put("status", if (entries.isEmpty() && days.values.none { validMood(it.mood) != null } && hasNoMarks() && plannedByDay.values.all { it.isEmpty() }) "empty" else "ok")
            .put("computed_at", Instant.now().toString())
            .put("queried", JSONObject().put("start", range.start.toString())
                .put("end", range.endExclusive.minusDays(1).toString()).put("inclusive", true).put("timezone", JigsawQuery.ZONE.id))
            .put("habits_configured", hasConfiguredHabits)
        if (query.command == "stats") root.put("stats", stats())
        else {
            val outputDays = JSONArray()
            for (day in range.startDay until range.endDay) outputDays.put(day(day))
            root.put("offset", query.offset).put("limit", query.limit).put("has_more", query.nextOffset != null)
                .putNullable("next_offset", query.nextOffset).put("days", outputDays)
        }
        return if (query.format == "md") markdown(root) else root.toString(2)
    }

    private fun day(day: Long): JSONObject {
        val rows = byDay[day].orEmpty()
        // 显式清空的日级心情不能被旧记录填回；没有日级设置时只取最后一条记录。
        val mood = if (days.containsKey(day)) validMood(days[day]?.mood) else validMood(rows.lastOrNull()?.mood)
        val habits = JSONArray()
        plannedByDay[day].orEmpty().forEach { habit ->
            val state = marks[habit.id to day]?.state
            habits.put(JSONObject().put("name", habit.title).put("done", state == HabitState.DONE).putNullable("state", state))
        }
        val updated = (rows.map { it.updatedAt } + listOfNotNull(days[day]?.updatedAt) +
            plannedByDay[day].orEmpty().mapNotNull { marks[it.id to day]?.updatedAt }).maxOrNull()
        return JSONObject().put("date", LocalDate.ofEpochDay(day).toString())
            .putNullable("text", rows.map { it.text }.filter { it.isNotBlank() }.takeIf { it.isNotEmpty() }?.joinToString("\n"))
            .putNullable("mood", mood).putNullable("mood_label", mood?.let { MOODS[it - 1] })
            .putNullable("mood_score", mood?.let { 6 - it }).putNullable("energy", mood?.let { 6 - it })
            .put("habits_configured", hasConfiguredHabits).put("habits", habits)
            .putNullable("created_at", rows.firstOrNull()?.createdAt?.let(::timestamp))
            .putNullable("updated_at", updated?.let(::timestamp))
            .put("records", JSONArray(rows.map(::record)))
    }

    private fun record(entry: MosaicEntry): JSONObject {
        val mood = validMood(entry.mood)
        return JSONObject().put("id", entry.id).putNullable("text", entry.text.takeIf { it.isNotBlank() })
            .putNullable("mood", mood).putNullable("mood_label", mood?.let { MOODS[it - 1] })
            .putNullable("mood_score", mood?.let { 6 - it }).putNullable("energy", mood?.let { 6 - it }).putNullable("habit", entry.habitTitle)
            .put("created_at_ms", entry.createdAt).put("updated_at_ms", entry.updatedAt)
            .put("created_at", timestamp(entry.createdAt)).put("updated_at", timestamp(entry.updatedAt))
    }

    private fun stats(): JSONObject {
        val energy = entries.mapNotNull { validMood(it.mood)?.let { mood -> 6 - mood } }
        val planned = plannedByDay.flatMap { (day, habits) -> habits.map { it.id to day } }
        val recorded = byDay.keys.count { it <= query.today }
        val future = (range.startDay until range.endDay).count { it > query.today }
        return JSONObject().put("days", range.length).put("recorded_days", recorded)
            .put("missing_days", range.length - recorded - future).put("future_days", future).put("records", entries.size)
            .put("mood_records", energy.size).putNullable("average_energy", energy.takeIf { it.isNotEmpty() }?.average())
            .put("habit_planned", planned.size).put("habit_done", planned.count { marks[it]?.state == HabitState.DONE })
    }

    private fun markdown(root: JSONObject): String = buildString {
        append("# Mosaic ${query.range.start} to ${query.range.endExclusive.minusDays(1)}\nTimezone: ${JigsawQuery.ZONE.id}\n")
        if (query.command == "stats") {
            val values = root.getJSONObject("stats")
            values.keys().forEach { key -> append("- $key: ${values.get(key)}\n") }
            return@buildString
        }
        val list = root.getJSONArray("days")
        for (index in 0 until list.length()) appendDay(list.getJSONObject(index))
        query.nextOffset?.let { append("\nMore days: repeat this query with --offset $it --limit ${query.limit}.\n") }
    }

    private fun StringBuilder.appendDay(day: JSONObject) {
        append("\n## ${day.getString("date")}\nMood: ${day.get("mood_label")}; energy: ${day.get("mood_score")}\n")
        val records = day.getJSONArray("records")
        if (records.length() == 0) append("No saved records.\n")
        for (index in 0 until records.length()) {
            val record = records.getJSONObject(index)
            append("\n### ${record.getString("created_at")}\nMood: ${record.get("mood_label")}; energy: ${record.get("mood_score")}\n")
            append(if (record.isNull("text")) "No text." else record.getString("text")).append('\n')
        }
        val habits = day.getJSONArray("habits")
        for (index in 0 until habits.length()) {
            val habit = habits.getJSONObject(index)
            append("- [${if (habit.getBoolean("done")) "x" else " "}] ${habit.getString("name")} (${habit.get("state")})\n")
        }
    }

    private fun timestamp(value: Long): String = DateTimeFormatter.ISO_OFFSET_DATE_TIME.format(Instant.ofEpochMilli(value).atZone(JigsawQuery.ZONE))
    private fun validMood(value: Int?): Int? = value?.takeIf { it in 1..5 }
    private fun hasNoMarks(): Boolean = marks.keys.none { it.second in range.startDay until range.endDay }
    private fun JSONObject.putNullable(key: String, value: Any?): JSONObject = put(key, value ?: JSONObject.NULL)

    companion object { private val MOODS = listOf("great", "good", "okay", "low", "bad") }
}
