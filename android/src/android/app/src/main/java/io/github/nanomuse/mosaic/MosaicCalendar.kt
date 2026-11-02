package io.github.nanomuse.mosaic

import java.time.DayOfWeek
import java.time.LocalDate
import java.time.temporal.TemporalAdjusters
import kotlin.math.max

/** The five time scales of the Mosaic page. The order is the order of the segments. */
enum class MosaicScope { DAY, WEEK, MONTH, QUARTER, YEAR }

/** A closed-open range of calendar days, `[start, endExclusive)`. */
data class MosaicRange(val start: LocalDate, val endExclusive: LocalDate) {
    val startDay: Long get() = start.toEpochDay()
    val endDay: Long get() = endExclusive.toEpochDay()
    val length: Int get() = (endDay - startDay).toInt()

    operator fun contains(day: LocalDate): Boolean = !day.isBefore(start) && day.isBefore(endExclusive)

    /** Days of the range that have begun by [today] (today included), 0 for a range still ahead. */
    fun elapsed(today: LocalDate): Int = (minOf(today.toEpochDay() + 1, endDay) - startDay).coerceIn(0L, length.toLong()).toInt()
}

/**
 * The calendar arithmetic behind the five views: which range an anchor date falls in, and where
 * the arrows go. Weeks start on Monday; quarters are calendar quarters (Q1 is January to March).
 */
object MosaicCalendar {
    fun weekStart(day: LocalDate): LocalDate = day.with(TemporalAdjusters.previousOrSame(DayOfWeek.MONDAY))

    fun quarterOf(day: LocalDate): Int = (day.monthValue - 1) / 3 + 1

    fun quarterStart(day: LocalDate): LocalDate = LocalDate.of(day.year, (quarterOf(day) - 1) * 3 + 1, 1)

    fun range(scope: MosaicScope, anchor: LocalDate): MosaicRange = when (scope) {
        MosaicScope.DAY -> MosaicRange(anchor, anchor.plusDays(1))
        MosaicScope.WEEK -> weekStart(anchor).let { MosaicRange(it, it.plusDays(7)) }
        MosaicScope.MONTH -> anchor.withDayOfMonth(1).let { MosaicRange(it, it.plusMonths(1)) }
        MosaicScope.QUARTER -> quarterStart(anchor).let { MosaicRange(it, it.plusMonths(3)) }
        MosaicScope.YEAR -> anchor.withDayOfYear(1).let { MosaicRange(it, it.plusYears(1)) }
    }

    /** One step of the arrows. `plusMonths` and `plusYears` clamp a day the target month lacks to its last day. */
    fun shift(scope: MosaicScope, anchor: LocalDate, steps: Long): LocalDate = when (scope) {
        MosaicScope.DAY -> anchor.plusDays(steps)
        MosaicScope.WEEK -> anchor.plusWeeks(steps)
        MosaicScope.MONTH -> anchor.plusMonths(steps)
        MosaicScope.QUARTER -> anchor.plusMonths(3 * steps)
        MosaicScope.YEAR -> anchor.plusYears(steps)
    }

    /** Drilling into a range: the anchor stays when it is inside, otherwise the range's first day. */
    fun anchorWithin(anchor: LocalDate, range: MosaicRange): LocalDate = if (anchor in range) anchor else range.start
}

/**
 * The part of an [imageWidth] × [imageHeight] picture shown in a [boxWidth] × [boxHeight] box:
 * scaled to cover the box, zoomed in by [zoom], centred on the focus as far as the picture's edges
 * allow. Every place that draws a photo (the day's shapes, the hearts, the calendar, the editor)
 * goes through this, so one focus reads the same in every container.
 */
object MosaicCrop {
    data class Source(val left: Float, val top: Float, val width: Float, val height: Float)

    fun source(
        imageWidth: Int,
        imageHeight: Int,
        boxWidth: Float,
        boxHeight: Float,
        focusX: Float,
        focusY: Float,
        zoom: Float,
    ): Source {
        val iw = imageWidth.toFloat()
        val ih = imageHeight.toFloat()
        val scale = max(boxWidth / iw, boxHeight / ih) * zoom.coerceIn(1f, MAX_ZOOM)
        val sw = (boxWidth / scale).coerceAtMost(iw)
        val sh = (boxHeight / scale).coerceAtMost(ih)
        val sx = (focusX * iw - sw / 2f).coerceIn(0f, iw - sw)
        val sy = (focusY * ih - sh / 2f).coerceIn(0f, ih - sh)
        return Source(sx, sy, sw, sh)
    }

    /**
     * A drag of ([dx], [dy]) box pixels in the editor, as the new focus: the picture follows the
     * finger, and the focus stops where the picture's edge reaches the box's.
     */
    fun drag(
        imageWidth: Int,
        imageHeight: Int,
        boxWidth: Float,
        boxHeight: Float,
        focusX: Float,
        focusY: Float,
        zoom: Float,
        dx: Float,
        dy: Float,
    ): Pair<Float, Float> {
        val iw = imageWidth.toFloat()
        val ih = imageHeight.toFloat()
        val scale = max(boxWidth / iw, boxHeight / ih) * zoom.coerceIn(1f, MAX_ZOOM)
        val halfW = (boxWidth / scale / iw / 2f).coerceAtMost(0.5f)
        val halfH = (boxHeight / scale / ih / 2f).coerceAtMost(0.5f)
        val x = (focusX.coerceIn(halfW, 1f - halfW) - dx / scale / iw).coerceIn(halfW, 1f - halfW)
        val y = (focusY.coerceIn(halfH, 1f - halfH) - dy / scale / ih).coerceIn(halfH, 1f - halfH)
        return x to y
    }

    const val MAX_ZOOM = 4f

    /** The default focus: centred, a little above the middle, where faces usually are. */
    const val DEFAULT_FOCUS_X = 0.5f
    const val DEFAULT_FOCUS_Y = 0.42f
}
