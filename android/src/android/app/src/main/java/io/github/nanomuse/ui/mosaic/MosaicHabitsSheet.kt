package io.github.nanomuse.ui.mosaic

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.outlined.CheckBox
import androidx.compose.material.icons.outlined.CheckBoxOutlineBlank
import androidx.compose.material.icons.outlined.IndeterminateCheckBox
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openminis.app.R
import com.openminis.app.ui.theme.ChatColors
import io.github.nanomuse.mosaic.HabitState
import io.github.nanomuse.mosaic.MosaicCalendar
import io.github.nanomuse.mosaic.MosaicHabit
import io.github.nanomuse.mosaic.MosaicPeriod
import io.github.nanomuse.mosaic.MosaicScope
import io.github.nanomuse.mosaic.MosaicShape
import io.github.nanomuse.mosaic.MosaicStore
import io.github.nanomuse.ui.home.MuseTones
import kotlinx.coroutines.launch
import java.time.DayOfWeek
import java.time.LocalDate
import java.time.format.TextStyle

/**
 * The habits of one day, in a sheet like the Goals page's: the box marks a habit done for that
 * day (the quickest record there is), the menu skips the day, pauses, edits or archives. A habit
 * not planned that day shows its box greyed. Nothing here deletes a habit's past.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MosaicHabitsSheet(store: MosaicStore, day: LocalDate, today: LocalDate, onDismiss: () -> Unit) {
    val range = remember(day) { MosaicCalendar.range(MosaicScope.DAY, day) }
    val period by remember(range) { store.period(range) }.collectAsState(initial = null)
    val coroutines = rememberCoroutineScope()
    val context = LocalContext.current
    val formats = rememberMosaicFormats()
    var editing by remember { mutableStateOf<MosaicHabit?>(null) }
    var adding by remember { mutableStateOf(false) }
    var archiving by remember { mutableStateOf<MosaicHabit?>(null) }
    val epoch = day.toEpochDay()
    val todayDay = today.toEpochDay()

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        containerColor = ChatColors.background,
    ) {
        Column(Modifier.navigationBarsPadding().verticalScroll(rememberScrollState()).padding(bottom = 16.dp)) {
            Text(
                stringResource(R.string.nm_mosaic_habits_title),
                fontSize = 20.sp,
                fontWeight = FontWeight.Bold,
                color = MaterialTheme.colorScheme.onSurface,
                modifier = Modifier.padding(horizontal = 24.dp),
            )
            Text(
                formats.day.format(day),
                fontSize = 13.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(start = 24.dp, end = 24.dp, top = 2.dp, bottom = 8.dp),
            )
            val p = period
            val active = p?.habits?.filter { h -> h.archivedDay.let { it == null || it > todayDay } }.orEmpty()
            if (p != null && active.isEmpty()) {
                Text(
                    stringResource(R.string.nm_mosaic_habits_none),
                    fontSize = 13.sp,
                    lineHeight = 18.sp,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(horizontal = 24.dp, vertical = 8.dp),
                )
            }
            if (p != null) {
                active.forEach { habit ->
                    HabitRow(
                        habit = habit,
                        period = p,
                        day = epoch,
                        todayDay = todayDay,
                        onState = { state -> coroutines.launch { runStoreCall(context) { store.setHabitState(habit.id, epoch, state, today) } } },
                        onEdit = { editing = habit },
                        onPause = { paused -> coroutines.launch { runStoreCall(context) { store.setPaused(habit, paused, today) } } },
                        onArchive = { archiving = habit },
                    )
                }
            }
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier
                    .fillMaxWidth()
                    .clickable { adding = true }
                    .heightIn(min = 52.dp)
                    .padding(horizontal = 24.dp),
            ) {
                Icon(Icons.Filled.Add, contentDescription = null, tint = MuseTones.action, modifier = Modifier.size(22.dp))
                Spacer(Modifier.width(12.dp))
                Text(stringResource(R.string.nm_mosaic_habit_add), fontSize = 15.sp, fontWeight = FontWeight.Medium, color = MuseTones.action)
            }
        }
    }

    if (adding) {
        HabitDialog(
            initial = null,
            initialWeekdays = MosaicPeriod.EVERY_DAY,
            onDismiss = { adding = false },
            onSave = { title, shape, weekdays ->
                adding = false
                coroutines.launch { runStoreCall(context) { store.addHabit(title, shape, weekdays, today) } }
            },
        )
    }
    editing?.let { habit ->
        // A paused habit shows the plan it had; only days the person changed become a new plan.
        val current = period?.lastPlan(habit.id, todayDay) ?: MosaicPeriod.EVERY_DAY
        HabitDialog(
            initial = habit,
            initialWeekdays = current,
            onDismiss = { editing = null },
            onSave = { title, shape, weekdays ->
                editing = null
                coroutines.launch {
                    runStoreCall(context) { store.updateHabit(habit, title, shape, weekdays.takeIf { it != current }, today) }
                }
            },
        )
    }
    archiving?.let { habit ->
        AlertDialog(
            onDismissRequest = { archiving = null },
            title = { Text(habit.title) },
            text = { Text(stringResource(R.string.nm_mosaic_archive_confirm, habit.title)) },
            confirmButton = {
                TextButton(onClick = {
                    archiving = null
                    coroutines.launch { runStoreCall(context) { store.archive(habit, today) } }
                }) { Text(stringResource(R.string.nm_mosaic_archive), color = MaterialTheme.colorScheme.error) }
            },
            dismissButton = { TextButton(onClick = { archiving = null }) { Text(stringResource(android.R.string.cancel)) } },
        )
    }
}

@Composable
private fun HabitRow(
    habit: MosaicHabit,
    period: MosaicPeriod,
    day: Long,
    todayDay: Long,
    onState: (String?) -> Unit,
    onEdit: () -> Unit,
    onPause: (Boolean) -> Unit,
    onArchive: () -> Unit,
) {
    var menu by remember { mutableStateOf(false) }
    val planned = period.isPlanned(habit, day)
    val state = period.state(habit.id, day)
    // A mark left on a day the habit is no longer planned can still be cleared.
    val markable = (planned || state != null) && day <= todayDay
    val paused = period.versionOn(habit.id, todayDay)?.weekdays == 0
    val stateText = stringResource(
        when (state) {
            HabitState.DONE -> R.string.nm_mosaic_state_done
            HabitState.SKIPPED -> R.string.nm_mosaic_state_skipped
            else -> if (planned) R.string.nm_mosaic_state_open else R.string.nm_mosaic_state_not_planned
        },
    )
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.fillMaxWidth().padding(start = 12.dp, end = 4.dp),
    ) {
        IconButton(
            onClick = { onState(if (state == HabitState.DONE) null else HabitState.DONE) },
            enabled = markable,
            modifier = Modifier.semantics { stateDescription = stateText },
        ) {
            Icon(
                when (state) {
                    HabitState.DONE -> Icons.Outlined.CheckBox
                    HabitState.SKIPPED -> Icons.Outlined.IndeterminateCheckBox
                    else -> Icons.Outlined.CheckBoxOutlineBlank
                },
                contentDescription = stringResource(if (state == HabitState.DONE) R.string.nm_a11y_mark_not_done else R.string.nm_a11y_mark_done),
                tint = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = if (markable) 1f else 0.4f),
                modifier = Modifier.size(22.dp),
            )
        }
        Column(Modifier.weight(1f).padding(vertical = 8.dp)) {
            Text(
                habit.title,
                fontSize = 15.sp,
                fontWeight = FontWeight.SemiBold,
                color = MaterialTheme.colorScheme.onSurface,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                scheduleText(period.versionOn(habit.id, todayDay)?.weekdays) + " · " + stateText,
                fontSize = 12.5.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        Box {
            IconButton(onClick = { menu = true }) {
                Icon(Icons.Filled.MoreVert, contentDescription = stringResource(R.string.nm_more), tint = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                DropdownMenuItem(text = { Text(stringResource(R.string.nm_mosaic_habit_edit)) }, onClick = { menu = false; onEdit() })
                if (markable) {
                    DropdownMenuItem(
                        text = { Text(stringResource(if (state == HabitState.SKIPPED) R.string.nm_mosaic_unskip else R.string.nm_mosaic_skip)) },
                        onClick = {
                            menu = false
                            onState(if (state == HabitState.SKIPPED) null else HabitState.SKIPPED)
                        },
                    )
                }
                DropdownMenuItem(
                    text = { Text(stringResource(if (paused) R.string.nm_mosaic_resume else R.string.nm_mosaic_pause)) },
                    onClick = { menu = false; onPause(!paused) },
                )
                DropdownMenuItem(
                    text = { Text(stringResource(R.string.nm_mosaic_archive), color = MaterialTheme.colorScheme.error) },
                    onClick = { menu = false; onArchive() },
                )
            }
        }
    }
}

/** "Every day", "Weekdays", "Mon, Wed, Fri" or "Paused", for a [weekdays] bit set. */
@Composable
private fun scheduleText(weekdays: Int?): String {
    val locale = LocalContext.current.resources.configuration.locales[0]
    return when (weekdays) {
        null -> ""
        0 -> stringResource(R.string.nm_mosaic_paused)
        MosaicPeriod.EVERY_DAY -> stringResource(R.string.nm_mosaic_every_day)
        MosaicPeriod.WORKDAYS -> stringResource(R.string.nm_mosaic_workdays)
        else -> (0..6).filter { weekdays and (1 shl it) != 0 }
            .joinToString(stringResource(R.string.nm_mosaic_list_separator)) { DayOfWeek.of(it + 1).getDisplayName(TextStyle.SHORT, locale) }
    }
}

/**
 * Adding or editing a habit: its name and its days. Its cloud in a day's shape is like every
 * other, so the stored shape is only carried through.
 */
@Composable
private fun HabitDialog(
    initial: MosaicHabit?,
    initialWeekdays: Int,
    onDismiss: () -> Unit,
    onSave: (String, MosaicShape, Int) -> Unit,
) {
    val locale = LocalContext.current.resources.configuration.locales[0]
    var title by remember { mutableStateOf(initial?.title.orEmpty()) }
    val shape = remember { MosaicShape.of(initial?.shape) }
    var weekdays by remember { mutableIntStateOf(initialWeekdays) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(if (initial == null) R.string.nm_mosaic_habit_add else R.string.nm_mosaic_habit_edit)) },
        text = {
            Column {
                OutlinedTextField(
                    value = title,
                    onValueChange = { title = it.take(TITLE_MAX) },
                    singleLine = true,
                    label = { Text(stringResource(R.string.nm_mosaic_habit_name)) },
                    shape = RoundedCornerShape(16.dp),
                    colors = OutlinedTextFieldDefaults.colors(focusedBorderColor = MuseTones.action, unfocusedBorderColor = MuseTones.hairline),
                    modifier = Modifier.fillMaxWidth(),
                )
                Spacer(Modifier.height(14.dp))
                Text(stringResource(R.string.nm_mosaic_habit_days), fontSize = 13.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                Spacer(Modifier.height(6.dp))
                Row(horizontalArrangement = Arrangement.SpaceBetween, modifier = Modifier.fillMaxWidth()) {
                    (0..6).forEach { i ->
                        val on = weekdays and (1 shl i) != 0
                        Box(
                            contentAlignment = Alignment.Center,
                            modifier = Modifier
                                .size(34.dp)
                                .clip(CircleShape)
                                .background(if (on) MaterialTheme.colorScheme.onSurface else MuseTones.fill)
                                .toggleable(value = on, role = Role.Checkbox) { weekdays = weekdays xor (1 shl i) },
                        ) {
                            Text(
                                DayOfWeek.of(i + 1).getDisplayName(TextStyle.NARROW, locale),
                                fontSize = 13.sp,
                                fontWeight = FontWeight.Medium,
                                color = if (on) MaterialTheme.colorScheme.surface else MaterialTheme.colorScheme.onSurface,
                            )
                        }
                    }
                }
                Spacer(Modifier.height(8.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    MosaicChip(stringResource(R.string.nm_mosaic_every_day), weekdays == MosaicPeriod.EVERY_DAY, onClick = { weekdays = MosaicPeriod.EVERY_DAY })
                    MosaicChip(stringResource(R.string.nm_mosaic_workdays), weekdays == MosaicPeriod.WORKDAYS, onClick = { weekdays = MosaicPeriod.WORKDAYS })
                }
                if (initial != null) {
                    Spacer(Modifier.height(10.dp))
                    Text(stringResource(R.string.nm_mosaic_habit_rule_note), fontSize = 12.sp, lineHeight = 16.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
        },
        confirmButton = {
            TextButton(
                enabled = title.isNotBlank() && weekdays != 0,
                onClick = { onSave(title, shape, weekdays) },
            ) { Text(stringResource(R.string.nm_mosaic_save)) }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text(stringResource(android.R.string.cancel)) } },
    )
}

private const val TITLE_MAX = 40
