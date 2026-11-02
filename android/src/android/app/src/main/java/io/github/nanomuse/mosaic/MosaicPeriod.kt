package io.github.nanomuse.mosaic

import java.time.LocalDate

/** The shapes a record or a habit slot can take. [id] is what the database stores. */
enum class MosaicShape(val id: String) {
    SQUARE("square"),
    ROUNDED("rounded"),
    CIRCLE("circle"),
    HEXAGON("hexagon"),
    TRIANGLE("triangle"),
    HEART("heart"),
    // The free-form shape has three fixed variants; the variant is stored, never re-rolled.
    BLOB_1("blob1"),
    BLOB_2("blob2"),
    BLOB_3("blob3"),
    ;

    val isBlob: Boolean get() = this == BLOB_1 || this == BLOB_2 || this == BLOB_3

    companion object {
        /** An unknown id (a newer version's shape, a damaged row) falls back to the rounded square. */
        fun of(id: String?): MosaicShape = entries.firstOrNull { it.id == id } ?: ROUNDED

        /** The seven choices the editor offers; the free-form one stands for its three variants. */
        val choices: List<MosaicShape> = listOf(SQUARE, ROUNDED, CIRCLE, HEXAGON, TRIANGLE, HEART, BLOB_1)
    }
}

/**
 * One day as every scale sees it. A day is recorded when it has a saved entry or a habit marked
 * done; a draft or an empty habit slot does not count. [cover] is the same entry wherever the day
 * is drawn, only the crop changes with the container.
 */
data class DaySummary(
    val day: Long,
    val entryCount: Int,
    val doneCount: Int,
    val cover: MosaicEntryRow?,
    val preview: String?,
) {
    val recorded: Boolean get() = entryCount > 0 || doneCount > 0
}

/** One cloud of a day's shape. */
sealed interface DayPiece {
    /** A saved record; [done] when its habit is marked done that day. */
    class Record(val row: MosaicEntryRow, val habit: MosaicHabit?, val done: Boolean) : DayPiece

    /** A habit planned that day with no record: marked done in the habits sheet, or still open. */
    class Habit(val habit: MosaicHabit, val done: Boolean) : DayPiece
}

/**
 * Everything the five views read for one range, from one query set: the counts on the day page,
 * the week cards, the hearts and the quarter's months all come out of the same rows.
 */
class MosaicPeriod(
    val range: MosaicRange,
    val entries: List<MosaicEntryRow>,
    habitDays: List<MosaicHabitDay>,
    days: List<MosaicDayInfo>,
    val habits: List<MosaicHabit>,
    schedules: List<MosaicHabitSchedule>,
) {
    private val byDay: Map<Long, List<MosaicEntryRow>> = entries.groupBy { it.entry.day }
    private val states: Map<Pair<String, Long>, String> = habitDays.associate { (it.habitId to it.day) to it.state }
    private val infoByDay: Map<Long, MosaicDayInfo> = days.associateBy { it.day }
    private val schedulesByHabit: Map<String, List<MosaicHabitSchedule>> = schedules.groupBy { it.habitId }
    private val habitById: Map<String, MosaicHabit> = habits.associateBy { it.id }

    // Only marks of habits planned that day count, as on the day page; a mark left after a plan change does not.
    private val doneByDay: Map<Long, Int> = habitDays
        .filter { d -> d.state == HabitState.DONE && habitById[d.habitId]?.let { isPlanned(it, d.day) } == true }
        .groupingBy { it.day }.eachCount()

    fun entriesOn(day: Long): List<MosaicEntryRow> = byDay[day].orEmpty()

    fun info(day: Long): MosaicDayInfo? = infoByDay[day]

    fun state(habitId: String, day: Long): String? = states[habitId to day]

    fun summary(day: Long): DaySummary {
        val rows = entriesOn(day)
        val chosen = info(day)?.coverEntryId
        val cover = rows.firstOrNull { it.entry.id == chosen && it.mediaPath != null }
            ?: rows.firstOrNull { it.mediaPath != null }
        val preview = rows.firstOrNull { it.entry.text.isNotBlank() }?.entry?.text?.trim()
        return DaySummary(day, rows.size, doneByDay[day] ?: 0, cover, preview)
    }

    /** Days in the range with a record, each day counted once however many entries it has. */
    fun recordedDays(): Int = (byDay.keys + doneByDay.keys).size

    /** The schedule version in force on [day], or null before the habit's first one. */
    fun versionOn(habitId: String, day: Long): MosaicHabitSchedule? =
        schedulesByHabit[habitId].orEmpty().lastOrNull { it.fromDay <= day }

    /** The weekdays of the last plan in force by [day] that had any, so a pause still knows its plan. */
    fun lastPlan(habitId: String, day: Long): Int? =
        schedulesByHabit[habitId].orEmpty().lastOrNull { it.fromDay <= day && it.weekdays != 0 }?.weekdays

    fun isPlanned(habit: MosaicHabit, day: Long): Boolean {
        val archived = habit.archivedDay
        if (archived != null && day >= archived) return false
        val version = versionOn(habit.id, day) ?: return false
        return version.weekdays and weekdayBit(day) != 0
    }

    /** The habits planned on [day], in the person's order. */
    fun planned(day: Long): List<MosaicHabit> = habits.filter { isPlanned(it, day) }

    /** The shape of [day]: the person's pick, else the automatic one. */
    fun formOf(day: Long): MosaicForm = MosaicForm.of(info(day)?.form) ?: MosaicForm.auto(day)

    /** What fills [day]'s shape, in order: its records as they were made, then planned habits that have no record. */
    fun pieces(day: Long): List<DayPiece> {
        val rows = entriesOn(day)
        val records = rows.map { row ->
            val habit = row.entry.habitId?.let(habitById::get)
            DayPiece.Record(row, habit, habit != null && state(habit.id, day) == HabitState.DONE)
        }
        val open = planned(day)
            .filter { habit -> rows.none { it.entry.habitId == habit.id } }
            .map { DayPiece.Habit(it, state(it.id, day) == HabitState.DONE) }
        return records + open
    }

    /** How many times each habit was marked done in the range, for the habits that were. */
    fun doneTimes(): List<Pair<MosaicHabit, Int>> {
        val counts = states.entries.filter { it.value == HabitState.DONE }.groupingBy { it.key.first }.eachCount()
        return habits.mapNotNull { h -> counts[h.id]?.let { h to it } }
    }

    companion object {
        /** Bit 0 Monday to bit 6 Sunday, the encoding of [MosaicHabitSchedule.weekdays]. */
        fun weekdayBit(day: Long): Int = 1 shl (LocalDate.ofEpochDay(day).dayOfWeek.value - 1)

        const val EVERY_DAY = 0b1111111
        const val WORKDAYS = 0b0011111
    }
}
