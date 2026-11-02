package io.github.nanomuse.ui.mosaic

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawWithCache
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.drawText
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openminis.app.R
import io.github.nanomuse.mosaic.DayPiece
import io.github.nanomuse.mosaic.DaySummary
import io.github.nanomuse.mosaic.MosaicCalendar
import io.github.nanomuse.mosaic.MosaicForm
import io.github.nanomuse.mosaic.MosaicPeriod
import io.github.nanomuse.mosaic.MosaicRange
import io.github.nanomuse.mosaic.MosaicScope
import io.github.nanomuse.mosaic.MosaicStore
import io.github.nanomuse.mosaic.recordDayStatus
import io.github.nanomuse.ui.home.MuseTones
import java.time.DayOfWeek
import java.time.LocalDate
import java.time.format.TextStyle as DateTextStyle

private fun MosaicPeriod?.summaryOf(day: LocalDate): DaySummary =
    this?.summary(day.toEpochDay()) ?: DaySummary(day.toEpochDay(), 0, 0, null, null)

/** A day as the small views draw it: its shape and what fills it. Before the rows load, the automatic shape stands empty. */
private class DayDrawing(val day: Long, val form: MosaicForm, val pieces: List<DayPiece>, val entryCount: Int?)

private fun MosaicPeriod?.drawing(day: Long): DayDrawing =
    DayDrawing(day, this?.formOf(day) ?: MosaicForm.auto(day), this?.pieces(day).orEmpty(), this?.summary(day)?.entryCount)

/** Whether a row of cards should stack: a narrow window or a large font gets one card per line. */
@Composable
private fun crowded(width: Dp, limit: Dp): Boolean = width < limit || LocalDensity.current.fontScale > 1.3f

/** The decode size for photos in a small shape: a cloud there is at most this wide. */
@Composable
private fun smallPhotoPx(): Int = with(LocalDensity.current) { 28.dp.roundToPx() }

// ── Week ────────────────────────────────────────────────────────────

/**
 * Seven days, each in its place: Monday to Sunday in rows of three, two and two (two per row when
 * the window is narrow). A card shows the day's own shape with what fills it, and a line of words
 * or that nothing was recorded; a day ahead shows its empty shape. Any card opens its day.
 */
@Composable
fun MosaicWeekView(
    range: MosaicRange,
    today: LocalDate,
    period: MosaicPeriod?,
    store: MosaicStore,
    formats: MosaicFormats,
    onOpenDay: (LocalDate) -> Unit,
) {
    val context = LocalContext.current
    val days = List(7) { range.start.plusDays(it.toLong()) }
    val drawings = remember(period, range) { days.map { period.drawing(it.toEpochDay()) } }
    val images = rememberPuzzlePhotos(store, remember(drawings) { drawings.flatMap { photoPaths(it.pieces) } }, smallPhotoPx())
    val recorded = period?.recordedDays() ?: 0
    val caption = when {
        range.start.isAfter(today) -> stringResource(R.string.nm_mosaic_week_sub_future)
        today in range -> stringResource(R.string.nm_mosaic_week_sub_ongoing, formats.weekday.format(today), recorded)
        else -> stringResource(R.string.nm_mosaic_week_sub_done, recorded)
    }
    Column(Modifier.fillMaxWidth()) {
        MosaicHeading(stringResource(R.string.nm_mosaic_week_title), caption)
        MosaicRecordLegend()
        Spacer(Modifier.height(12.dp))
        BoxWithConstraints(Modifier.fillMaxWidth().padding(horizontal = 16.dp)) {
            val available = maxWidth
            val rows = if (crowded(available, 340.dp)) listOf(2, 2, 2, 1) else listOf(3, 2, 2)
            val gap = 10.dp
            Column(verticalArrangement = Arrangement.spacedBy(gap)) {
                var index = 0
                rows.forEach { count ->
                    val cardWidth = (available - gap * (count - 1)) / count
                    Row(horizontalArrangement = Arrangement.spacedBy(gap)) {
                        repeat(count) {
                            val i = index++
                            val date = days[i]
                            WeekCard(
                                date = date,
                                drawing = drawings[i],
                                summary = period.summaryOf(date),
                                today = today,
                                images = images,
                                formats = formats,
                                width = cardWidth,
                                onOpen = { onOpenDay(date) },
                            )
                        }
                    }
                }
            }
        }
        Spacer(Modifier.height(14.dp))
        val times = period?.doneTimes().orEmpty()
        Surface(
            shape = RoundedCornerShape(14.dp),
            color = MuseTones.fill,
            modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp),
        ) {
            Column(Modifier.padding(horizontal = 16.dp, vertical = 14.dp)) {
                Text(
                    stringResource(R.string.nm_mosaic_week_summary),
                    fontSize = 15.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = MaterialTheme.colorScheme.onSurface,
                )
                Spacer(Modifier.height(4.dp))
                Text(
                    if (times.isEmpty()) stringResource(R.string.nm_mosaic_week_no_habits)
                    else times.joinToString(context.getString(R.string.nm_mosaic_list_separator)) { (habit, n) ->
                        context.getString(R.string.nm_mosaic_habit_times, habit.title, n)
                    },
                    fontSize = 13.sp,
                    lineHeight = 18.sp,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
    }
}

@Composable
private fun WeekCard(
    date: LocalDate,
    drawing: DayDrawing,
    summary: DaySummary,
    today: LocalDate,
    images: Map<String, androidx.compose.ui.graphics.ImageBitmap>,
    formats: MosaicFormats,
    width: Dp,
    onOpen: () -> Unit,
) {
    val isToday = date == today
    val ahead = date.isAfter(today)
    Surface(
        onClick = onOpen,
        shape = RoundedCornerShape(14.dp),
        color = MuseTones.surface,
        border = BorderStroke(
            if (isToday) 2.dp else 1.dp,
            if (isToday) MaterialTheme.colorScheme.onSurface else MuseTones.hairline,
        ),
        modifier = Modifier.width(width),
    ) {
        Column(Modifier.padding(8.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(start = 2.dp, bottom = 6.dp)) {
                MosaicDateNumber(drawing.day, today.toEpochDay(), drawing.entryCount)
                Spacer(Modifier.width(4.dp))
                Text(
                    formats.weekday.format(date),
                    fontSize = 12.5.sp,
                    fontWeight = if (isToday) FontWeight.SemiBold else FontWeight.Normal,
                    color = MaterialTheme.colorScheme.onSurface,
                    maxLines = 1,
                    modifier = Modifier.weight(1f),
                )
                when {
                    isToday -> Text(stringResource(R.string.nm_mosaic_today), fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurface)
                    summary.entryCount > 1 -> Text(summary.entryCount.toString(), fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
            MosaicMiniPuzzle(drawing.form, drawing.pieces, ahead, images, Modifier.fillMaxWidth().height(84.dp))
            Spacer(Modifier.height(6.dp))
            Text(
                when {
                    ahead -> stringResource(R.string.nm_mosaic_not_yet)
                    summary.preview != null -> summary.preview
                    summary.recorded -> stringResource(R.string.nm_mosaic_done_only)
                    else -> stringResource(R.string.nm_mosaic_no_record)
                },
                fontSize = 11.5.sp,
                lineHeight = 15.sp,
                color = if (summary.recorded) MaterialTheme.colorScheme.onSurface else MaterialTheme.colorScheme.onSurfaceVariant,
                textAlign = TextAlign.Center,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.fillMaxWidth(),
            )
        }
    }
}

// ── Month ───────────────────────────────────────────────────────────

/**
 * The month as a Monday-first calendar whose every cell is that day's small shape. A tap selects a
 * day and previews it below; the preview opens it. Days ahead keep their empty shapes.
 */
@Composable
fun MosaicMonthView(
    range: MosaicRange,
    anchor: LocalDate,
    today: LocalDate,
    period: MosaicPeriod?,
    store: MosaicStore,
    formats: MosaicFormats,
    onSelect: (LocalDate) -> Unit,
    onOpenDay: (LocalDate) -> Unit,
) {
    val recorded = period?.recordedDays() ?: 0
    val description = stringResource(R.string.nm_mosaic_month_a11y, formats.yearMonth.format(anchor), recorded)
    Column(Modifier.fillMaxWidth()) {
        MosaicHeading(title = stringResource(R.string.nm_mosaic_month_title), caption = null)
        MosaicRecordLegend()
        Spacer(Modifier.height(12.dp))
        MonthGrid(
            month = range,
            period = period,
            today = today,
            store = store,
            selected = anchor.toEpochDay(),
            weekdays = true,
            onDay = onSelect,
            modifier = Modifier.semantics { contentDescription = description },
        )
        Spacer(Modifier.height(10.dp))
        MosaicStat(
            count = recorded,
            label = pluralStringResource(R.plurals.nm_mosaic_days_recorded, recorded),
            caption = when {
                range.start.isAfter(today) -> stringResource(R.string.nm_mosaic_not_yet)
                today in range -> stringResource(R.string.nm_mosaic_month_sub_ongoing, formats.monthDay.format(today))
                else -> stringResource(R.string.nm_mosaic_month_sub_done, recorded, range.length)
            },
        )
        MosaicDayPreview(
            date = anchor,
            summary = period.summaryOf(anchor),
            today = today,
            store = store,
            formats = formats,
            onOpen = { onOpenDay(anchor) },
        )
    }
}

/** One month as a Monday-first calendar of small shapes; the leading blanks belong to the month before. */
@Composable
private fun MonthGrid(
    month: MosaicRange,
    period: MosaicPeriod?,
    today: LocalDate,
    store: MosaicStore,
    selected: Long?,
    weekdays: Boolean,
    onDay: (LocalDate) -> Unit,
    modifier: Modifier = Modifier,
) {
    val locale = LocalContext.current.resources.configuration.locales[0]
    val lead = month.start.dayOfWeek.value - 1
    val weeks = (lead + month.length + 6) / 7
    val drawings = remember(period, month) { List(month.length) { period.drawing(month.startDay + it) } }
    val images = rememberPuzzlePhotos(store, remember(drawings) { drawings.flatMap { photoPaths(it.pieces) } }, smallPhotoPx())
    val todayDay = today.toEpochDay()
    Column(
        verticalArrangement = Arrangement.spacedBy(4.dp),
        modifier = modifier.fillMaxWidth().padding(horizontal = 16.dp),
    ) {
        if (weekdays) {
            Row {
                DayOfWeek.values().forEach { dow ->
                    Text(
                        dow.getDisplayName(DateTextStyle.NARROW, locale),
                        fontSize = 12.sp,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        textAlign = TextAlign.Center,
                        modifier = Modifier.weight(1f),
                    )
                }
            }
        }
        repeat(weeks) { w ->
            Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                repeat(7) { d ->
                    val i = w * 7 + d - lead
                    Box(Modifier.weight(1f).aspectRatio(CELL_RATIO)) {
                        drawings.getOrNull(i)?.let { drawing ->
                            DayCell(drawing, todayDay, drawing.day == selected, images) { onDay(LocalDate.ofEpochDay(drawing.day)) }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun DayCell(
    drawing: DayDrawing,
    today: Long,
    selected: Boolean,
    images: Map<String, androidx.compose.ui.graphics.ImageBitmap>,
    onClick: () -> Unit,
) {
    val shape = RoundedCornerShape(8.dp)
    val ink = MaterialTheme.colorScheme.onSurface
    val isToday = drawing.day == today
    val ahead = drawing.day > today
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        modifier = Modifier
            .fillMaxSize()
            .clip(shape)
            .then(
                when {
                    selected -> Modifier.border(2.dp, ink, shape)
                    isToday -> Modifier.border(1.dp, ink, shape)
                    else -> Modifier
                },
            )
            .clickable(onClick = onClick)
            .padding(2.dp),
    ) {
        MosaicDateNumber(drawing.day, today, drawing.entryCount)
        MosaicMiniPuzzle(drawing.form, drawing.pieces, ahead, images, Modifier.fillMaxWidth().weight(1f))
    }
}

// ── Quarter ─────────────────────────────────────────────────────────

/**
 * A calendar quarter as its three month calendars one under the other, every day its own small
 * shape. A day opens that day; a month's name opens the month.
 */
@Composable
fun MosaicQuarterView(
    range: MosaicRange,
    today: LocalDate,
    period: MosaicPeriod?,
    store: MosaicStore,
    formats: MosaicFormats,
    onOpenMonth: (LocalDate) -> Unit,
    onOpenDay: (LocalDate) -> Unit,
) {
    val months = List(3) { range.start.plusMonths(it.toLong()) }
    val recorded = period?.recordedDays() ?: 0
    Column(Modifier.fillMaxWidth()) {
        MosaicHeading(stringResource(R.string.nm_mosaic_quarter_heading), stringResource(R.string.nm_mosaic_quarter_caption))
        MosaicRecordLegend()
        Spacer(Modifier.height(6.dp))
        months.forEachIndexed { index, first ->
            val month = MosaicCalendar.range(MosaicScope.MONTH, first)
            val monthRecorded = remember(period, month) {
                (0 until month.length).count { period?.summary(month.startDay + it)?.recorded == true }
            }
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier
                    .fillMaxWidth()
                    .clickable { onOpenMonth(first) }
                    .heightIn(min = 48.dp)
                    .padding(horizontal = 20.dp),
            ) {
                Text(
                    formats.month.format(first),
                    fontSize = 15.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = MaterialTheme.colorScheme.onSurface,
                    modifier = Modifier.weight(1f),
                )
                Text(
                    when {
                        first.isAfter(today) -> stringResource(R.string.nm_mosaic_not_yet)
                        monthRecorded == 0 -> stringResource(R.string.nm_mosaic_no_record)
                        else -> pluralStringResource(R.plurals.nm_mosaic_month_recorded, monthRecorded, monthRecorded)
                    },
                    fontSize = 12.sp,
                    color = if (monthRecorded > 0) MuseTones.action else MaterialTheme.colorScheme.onSurfaceVariant,
                )
                Icon(
                    Icons.AutoMirrored.Filled.KeyboardArrowRight,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.size(20.dp),
                )
            }
            MonthGrid(
                month = month,
                period = period,
                today = today,
                store = store,
                selected = null,
                weekdays = index == 0,
                onDay = onOpenDay,
            )
            Spacer(Modifier.height(10.dp))
        }
        MosaicStat(
            count = recorded,
            label = pluralStringResource(R.plurals.nm_mosaic_days_recorded, recorded),
            caption = when {
                range.start.isAfter(today) -> stringResource(R.string.nm_mosaic_not_yet)
                today in range -> stringResource(R.string.nm_mosaic_quarter_sub_ongoing, range.elapsed(today), range.length)
                else -> stringResource(R.string.nm_mosaic_quarter_sub_done, range.length)
            },
        )
        // A piece per month that has records: its latest one, in date order. Chosen by rule, not by a model.
        val pieces = remember(period) {
            period?.let { p -> months.mapNotNull { first -> p.entries.lastOrNull { LocalDate.ofEpochDay(it.entry.day).month == first.month } } }.orEmpty()
        }
        Text(
            stringResource(R.string.nm_mosaic_quarter_pieces),
            fontSize = 15.sp,
            fontWeight = FontWeight.SemiBold,
            color = MaterialTheme.colorScheme.onSurface,
            modifier = Modifier.padding(start = 20.dp, end = 20.dp, top = 8.dp, bottom = 4.dp),
        )
        if (pieces.isEmpty()) {
            Text(
                stringResource(R.string.nm_mosaic_quarter_pieces_none),
                fontSize = 13.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(horizontal = 20.dp, vertical = 4.dp),
            )
        }
        pieces.forEach { row ->
            val date = LocalDate.ofEpochDay(row.entry.day)
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier
                    .fillMaxWidth()
                    .clickable { onOpenDay(date) }
                    .heightIn(min = 56.dp)
                    .padding(horizontal = 20.dp, vertical = 6.dp),
            ) {
                Box(Modifier.size(44.dp).clip(CloudShape).background(noteTint)) {
                    if (row.mediaPath != null) MosaicPhoto(row, store, 44.dp, Modifier.fillMaxSize())
                }
                Spacer(Modifier.width(12.dp))
                Column(Modifier.weight(1f)) {
                    Text(
                        formats.snippet.format(date) + " · " + row.entry.text.trim().ifEmpty { row.entry.habitTitle.orEmpty() },
                        fontSize = 14.sp,
                        color = MaterialTheme.colorScheme.onSurface,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                    row.entry.habitTitle?.let {
                        Text(it, fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1)
                    }
                }
            }
        }
    }
}

// ── Year ────────────────────────────────────────────────────────────

/**
 * The year as twelve small month calendars, every day a dot-sized shape: at this scale the shapes
 * and how full they are read, the photos do not. A month opens its calendar; the quarter buttons
 * open a quarter.
 */
@Composable
fun MosaicYearView(
    range: MosaicRange,
    today: LocalDate,
    period: MosaicPeriod?,
    formats: MosaicFormats,
    onOpenMonth: (LocalDate) -> Unit,
    onOpenQuarter: (LocalDate) -> Unit,
) {
    val recorded = period?.recordedDays() ?: 0
    val months = List(12) { range.start.plusMonths(it.toLong()) }
    Column(Modifier.fillMaxWidth()) {
        MosaicHeading(stringResource(R.string.nm_mosaic_year_heading), stringResource(R.string.nm_mosaic_year_caption))
        MosaicRecordLegend()
        Spacer(Modifier.height(12.dp))
        BoxWithConstraints(Modifier.fillMaxWidth().padding(horizontal = 16.dp)) {
            val columns = if (crowded(maxWidth, 330.dp)) 2 else 3
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                months.chunked(columns).forEach { row ->
                    Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        row.forEach { first ->
                            YearMonth(first, today, period, formats, Modifier.weight(1f)) { onOpenMonth(first) }
                        }
                        repeat(columns - row.size) { Spacer(Modifier.weight(1f)) }
                    }
                }
            }
        }
        Spacer(Modifier.height(10.dp))
        MosaicStat(
            count = recorded,
            label = pluralStringResource(R.plurals.nm_mosaic_days_recorded, recorded),
            caption = when {
                range.start.isAfter(today) -> stringResource(R.string.nm_mosaic_not_yet)
                today in range -> stringResource(R.string.nm_mosaic_year_sub_ongoing, formats.monthDay.format(today), range.elapsed(today))
                else -> stringResource(R.string.nm_mosaic_year_sub_done, range.length)
            },
        )
        Row(
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 6.dp),
        ) {
            (1..4).forEach { q ->
                MosaicChip(
                    label = stringResource(R.string.nm_mosaic_quarter_chip, q),
                    selected = today in range && MosaicCalendar.quarterOf(today) == q,
                    onClick = { onOpenQuarter(LocalDate.of(range.start.year, (q - 1) * 3 + 1, 1)) },
                    modifier = Modifier.weight(1f),
                )
            }
        }
    }
}

/** One month of the year: its name over a 7 × 6 grid of tiny shapes, drawn on a single canvas. */
@Composable
private fun YearMonth(
    first: LocalDate,
    today: LocalDate,
    period: MosaicPeriod?,
    formats: MosaicFormats,
    modifier: Modifier,
    onOpen: () -> Unit,
) {
    val month = remember(first) { MosaicCalendar.range(MosaicScope.MONTH, first) }
    val drawings = remember(period, month) { List(month.length) { period.drawing(month.startDay + it) } }
    val inks = rememberPuzzleInks()
    val markerColors = recordRingColors()
    val textMeasurer = rememberTextMeasurer()
    val ink = MaterialTheme.colorScheme.onSurface
    val todayDay = today.toEpochDay()
    val lead = first.dayOfWeek.value - 1
    Surface(
        onClick = onOpen,
        shape = RoundedCornerShape(12.dp),
        color = MuseTones.surface,
        border = BorderStroke(1.dp, MuseTones.hairline),
        modifier = modifier,
    ) {
        Column(Modifier.padding(8.dp)) {
            Text(
                formats.month.format(first),
                fontSize = 13.sp,
                fontWeight = FontWeight.SemiBold,
                color = MaterialTheme.colorScheme.onSurface,
                modifier = Modifier.padding(start = 2.dp, bottom = 4.dp),
            )
            Spacer(
                Modifier
                    .fillMaxWidth()
                    .aspectRatio(7f / (6f * 1.65f))
                    .drawWithCache {
                        val cell = size.width / 7f
                        val cellHeight = cell * 1.65f
                        val pad = cell * 0.06f
                        val labels = drawings.map { drawing ->
                            textMeasurer.measure(LocalDate.ofEpochDay(drawing.day).dayOfMonth.toString(),
                                TextStyle(color = ink.copy(alpha = if (drawing.day > todayDay) .6f else 1f), fontSize = 7.sp))
                        }
                        val days = drawings.mapIndexed { i, drawing ->
                            val slot = lead + i
                            val topLeft = Offset((slot % 7) * cell + pad, (slot / 7) * cellHeight + pad)
                            val clouds = placeClouds(PuzzleLayout(drawing.form, drawing.pieces.size),
                                topLeft + Offset(0f, cell * .8f), Size(cell - 2 * pad, cellHeight - cell * .8f - 2 * pad))
                            Triple(drawing, topLeft, clouds)
                        }
                        val ring = Stroke(1.dp.toPx())
                        onDrawBehind {
                            days.forEachIndexed { index, (drawing, topLeft, clouds) ->
                                val center = topLeft + Offset(cell * .5f - pad, cell * .4f)
                                markerColors.forStatus(recordDayStatus(drawing.day, todayDay, drawing.entryCount))?.let { color ->
                                    drawCircle(color, radius = cell * .4f, center = center, style = ring)
                                }
                                val label = labels[index]
                                drawText(label, topLeft = center - Offset(label.size.width / 2f, label.size.height / 2f))
                                paintPuzzle(clouds, drawing.pieces, inks, emptyMap(), drawing.day > todayDay)
                                if (drawing.day == todayDay) {
                                    drawRoundRect(
                                        ink,
                                        topLeft = topLeft - Offset(pad, pad),
                                        size = Size(cell, cellHeight),
                                        cornerRadius = CornerRadius(cell * 0.2f),
                                        style = ring,
                                    )
                                }
                            }
                        }
                    },
            )
        }
    }
}

/** A calendar cell is a little taller than wide: the day's number sits above its shape. */
private const val CELL_RATIO = 0.82f
