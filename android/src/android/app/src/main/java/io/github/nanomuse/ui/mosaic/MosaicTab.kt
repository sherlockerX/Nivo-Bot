package io.github.nanomuse.ui.mosaic

import android.util.Log
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.material3.DatePicker
import androidx.compose.material3.DatePickerDefaults
import androidx.compose.material3.DatePickerDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.SelectableDates
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberDatePickerState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.repeatOnLifecycle
import com.openminis.app.R
import com.openminis.app.ui.theme.ChatColors
import io.github.nanomuse.mosaic.MosaicCalendar
import io.github.nanomuse.mosaic.MosaicPeriod
import io.github.nanomuse.mosaic.MosaicScope
import io.github.nanomuse.mosaic.MosaicStore
import io.github.nanomuse.ui.library.Segmented
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneOffset
import java.time.temporal.IsoFields

/**
 * The Mosaic tab: day, week, month, quarter and year over one set of records. The five scales
 * share one anchor date, so switching scale shows the period that holds it; the arrows move one
 * period; opening a card (a week's day, a quarter's month, a year's quarter) is a step in, and
 * Back steps out to where the person came from, scroll position included.
 */
@Composable
fun MosaicTab(
    header: @Composable () -> Unit,
    onOpenEditor: (String) -> Unit,
    bottomInset: Dp = 0.dp,
) {
    val context = LocalContext.current
    val store = remember { MosaicStore.get(context) }
    val formats = rememberMosaicFormats()
    val today = rememberToday()
    val coroutines = rememberCoroutineScope()

    var scopeName by rememberSaveable { mutableStateOf(MosaicScope.DAY.name) }
    val scope = MosaicScope.entries.firstOrNull { it.name == scopeName } ?: MosaicScope.DAY
    var anchorDay by rememberSaveable { mutableLongStateOf(LocalDate.now().toEpochDay()) }
    val anchor = LocalDate.ofEpochDay(anchorDay)
    // Past midnight a page left on today moves to the new today, so a photo is not filed under yesterday.
    var seenToday by rememberSaveable { mutableLongStateOf(today.toEpochDay()) }
    LaunchedEffect(today) {
        val now = today.toEpochDay()
        if (now != seenToday) {
            if (anchorDay == seenToday) anchorDay = now
            seenToday = now
        }
    }
    // Where Back returns to after a step in: "SCOPE:epochDay" pairs, newest last.
    var trail by rememberSaveable { mutableStateOf("") }
    // Saved, so coming back from the editor keeps each scale's scroll position.
    val lists = MosaicScope.entries.associateWith { s ->
        key(s.name) { rememberSaveable(saver = LazyListState.Saver) { LazyListState() } }
    }

    fun stepInto(target: MosaicScope, day: LocalDate) {
        trail = (if (trail.isEmpty()) "" else "$trail;") + "${scope.name}:$anchorDay"
        scopeName = target.name
        anchorDay = day.toEpochDay()
    }
    BackHandler(enabled = trail.isNotEmpty()) {
        val last = trail.substringAfterLast(';')
        trail = if (';' in trail) trail.substringBeforeLast(';') else ""
        scopeName = last.substringBefore(':')
        last.substringAfter(':').toLongOrNull()?.let { anchorDay = it }
    }

    LaunchedEffect(Unit) {
        if (MosaicUi.swept.compareAndSet(false, true)) {
            try {
                store.sweep()
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                // Housekeeping only: a full disk must not keep the tab from opening.
                Log.w("Mosaic", "sweep failed", e)
            }
        }
    }
    val showDay by MosaicUi.showDay.collectAsState()
    LaunchedEffect(showDay) {
        val day = showDay ?: return@LaunchedEffect
        MosaicUi.showDay.value = null
        scopeName = MosaicScope.DAY.name
        anchorDay = day
        trail = ""
    }

    val range = remember(scope, anchorDay) { MosaicCalendar.range(scope, anchor) }
    var latest by remember { mutableStateOf<MosaicPeriod?>(null) }
    LaunchedEffect(range) { store.period(range).collect { latest = it } }
    // The previous range's rows stay on screen until the new ones arrive; a view only reads rows of its own range.
    val period = latest?.takeIf { it.range == range }

    var habitsOpen by remember { mutableStateOf(false) }
    // The entry just moved to the bin and its day; only that day's page offers Undo.
    var deleted by remember { mutableStateOf<Pair<String, Long>?>(null) }
    val deletedInEditor by MosaicUi.deleted.collectAsState()
    LaunchedEffect(deletedInEditor) {
        val gone = deletedInEditor ?: return@LaunchedEffect
        MosaicUi.deleted.value = null
        deleted = gone
    }
    LaunchedEffect(deleted) {
        if (deleted != null) {
            delay(UNDO_MS)
            deleted = null
        }
    }

    // The date bar: the period's name, and what places it in the calendar.
    val heading: Pair<String, String?> = when (scope) {
        MosaicScope.DAY -> formats.day.format(anchor) to
            stringResource(if (anchor == today) R.string.nm_mosaic_day_sub_today else R.string.nm_mosaic_day_sub, anchor.year)
        MosaicScope.WEEK -> formats.range(range.start, range.endExclusive.minusDays(1)) to
            stringResource(
                R.string.nm_mosaic_week_sub,
                range.start.get(IsoFields.WEEK_BASED_YEAR),
                range.start.get(IsoFields.WEEK_OF_WEEK_BASED_YEAR),
            )
        MosaicScope.MONTH -> formats.yearMonth.format(anchor) to null
        MosaicScope.QUARTER -> stringResource(R.string.nm_mosaic_quarter_title, anchor.year, MosaicCalendar.quarterOf(anchor)) to
            formats.range(range.start, range.endExclusive.minusDays(1))
        MosaicScope.YEAR -> stringResource(R.string.nm_mosaic_year_title, anchor.year) to
            pluralStringResource(R.plurals.nm_mosaic_year_places, range.length, range.length)
    }

    LazyColumn(
        state = lists.getValue(scope),
        modifier = Modifier.fillMaxSize().background(ChatColors.background),
        // The last row ends above the floating pill, which overlays the page.
        contentPadding = PaddingValues(bottom = 24.dp + bottomInset),
    ) {
        item(key = "header") { header() }
        item(key = "scales") {
            Segmented(
                labels = listOf(
                    stringResource(R.string.nm_mosaic_scope_day),
                    stringResource(R.string.nm_mosaic_scope_week),
                    stringResource(R.string.nm_mosaic_scope_month),
                    stringResource(R.string.nm_mosaic_scope_quarter),
                    stringResource(R.string.nm_mosaic_scope_year),
                ),
                selected = scope.ordinal,
                onSelect = { i ->
                    scopeName = MosaicScope.entries[i].name
                    trail = ""
                },
                modifier = Modifier.padding(horizontal = 16.dp, vertical = 10.dp),
            )
        }
        item(key = "dates") {
            MosaicDateBar(
                title = heading.first,
                subtitle = heading.second,
                onPrevious = { anchorDay = MosaicCalendar.shift(scope, anchor, -1).toEpochDay() },
                onNext = { anchorDay = MosaicCalendar.shift(scope, anchor, 1).toEpochDay() },
                onPick = { MosaicUi.datePickerOpen.value = true },
            )
        }
        item(key = "view-" + scope.name) {
            when (scope) {
                MosaicScope.DAY -> MosaicDayView(
                    day = anchor,
                    today = today,
                    period = period,
                    store = store,
                    onOpenEditor = onOpenEditor,
                    onOpenHabits = { habitsOpen = true },
                    deleted = deleted?.takeIf { it.second == anchorDay }?.first,
                    onDelete = { id ->
                        val day = anchorDay
                        coroutines.launch {
                            if (runStoreCall(context) { store.delete(id) }) deleted = id to day
                        }
                    },
                    onUndo = {
                        val id = deleted?.first ?: return@MosaicDayView
                        deleted = null
                        coroutines.launch { runStoreCall(context) { store.restore(id) } }
                    },
                )
                MosaicScope.WEEK -> MosaicWeekView(
                    range = range,
                    today = today,
                    period = period,
                    store = store,
                    formats = formats,
                    onOpenDay = { stepInto(MosaicScope.DAY, it) },
                )
                MosaicScope.MONTH -> MosaicMonthView(
                    range = range,
                    anchor = anchor,
                    today = today,
                    period = period,
                    store = store,
                    formats = formats,
                    onSelect = { anchorDay = it.toEpochDay() },
                    onOpenDay = { stepInto(MosaicScope.DAY, it) },
                )
                MosaicScope.QUARTER -> MosaicQuarterView(
                    range = range,
                    today = today,
                    period = period,
                    store = store,
                    formats = formats,
                    onOpenMonth = { first ->
                        stepInto(MosaicScope.MONTH, MosaicCalendar.anchorWithin(anchor, MosaicCalendar.range(MosaicScope.MONTH, first)))
                    },
                    onOpenDay = { stepInto(MosaicScope.DAY, it) },
                )
                MosaicScope.YEAR -> MosaicYearView(
                    range = range,
                    today = today,
                    period = period,
                    formats = formats,
                    onOpenMonth = { first ->
                        stepInto(MosaicScope.MONTH, MosaicCalendar.anchorWithin(anchor, MosaicCalendar.range(MosaicScope.MONTH, first)))
                    },
                    onOpenQuarter = { first ->
                        stepInto(MosaicScope.QUARTER, MosaicCalendar.anchorWithin(anchor, MosaicCalendar.range(MosaicScope.QUARTER, first)))
                    },
                )
            }
        }
    }

    val pickerOpen by MosaicUi.datePickerOpen.collectAsState()
    if (pickerOpen) {
        MosaicDatePicker(
            initial = anchor,
            today = today,
            onPick = { picked ->
                anchorDay = picked.toEpochDay()
                trail = ""
            },
            onDismiss = { MosaicUi.datePickerOpen.value = false },
        )
    }
    if (habitsOpen) {
        MosaicHabitsSheet(
            store = store,
            day = anchor,
            today = today,
            onDismiss = { habitsOpen = false },
        )
    }
}

/** Today's date, read again whenever the page comes back and once a minute while it is shown. */
@Composable
fun rememberToday(): LocalDate {
    var today by remember { mutableStateOf(LocalDate.now()) }
    val owner = LocalLifecycleOwner.current
    LaunchedEffect(owner) {
        owner.repeatOnLifecycle(Lifecycle.State.RESUMED) {
            while (true) {
                today = LocalDate.now()
                delay(60_000)
            }
        }
    }
    return today
}

/** How long the "Deleted · Undo" line stays. */
private const val UNDO_MS = 6_000L
