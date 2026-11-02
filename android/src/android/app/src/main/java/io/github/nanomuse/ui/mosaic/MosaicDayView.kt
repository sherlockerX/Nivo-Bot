package io.github.nanomuse.ui.mosaic

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.outlined.EditNote
import androidx.compose.material.icons.outlined.Image
import androidx.compose.material.icons.outlined.ModeEdit
import androidx.compose.material.icons.outlined.PhotoCamera
import androidx.compose.material.icons.outlined.TaskAlt
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.min
import androidx.compose.ui.unit.sp
import com.openminis.app.R
import io.github.nanomuse.mosaic.DayPiece
import io.github.nanomuse.mosaic.HabitState
import io.github.nanomuse.mosaic.MosaicEntryRow
import io.github.nanomuse.mosaic.MosaicForm
import io.github.nanomuse.mosaic.MosaicHabit
import io.github.nanomuse.mosaic.MosaicPeriod
import io.github.nanomuse.mosaic.MosaicStore
import io.github.nanomuse.ui.home.MuseTones
import kotlinx.coroutines.launch
import java.time.LocalDate

/**
 * The day page: the day's shape (a heart, a diamond…) made of clouds, one per record or planned
 * habit, the places still empty drawn dashed; then the ways in (camera, album, a sentence), the
 * day's records as a list, and its habits. A planned habit's cloud is a plan, not a record: it
 * counts for nothing until something is saved in it or it is marked done. Days ahead show their
 * shape and plan and no way in.
 */
@Composable
fun MosaicDayView(
    day: LocalDate,
    today: LocalDate,
    period: MosaicPeriod?,
    store: MosaicStore,
    onOpenEditor: (String) -> Unit,
    onOpenHabits: () -> Unit,
    deleted: String?,
    onDelete: (String) -> Unit,
    onUndo: () -> Unit,
) {
    val epoch = day.toEpochDay()
    val ahead = day.isAfter(today)
    val entries = period?.entriesOn(epoch).orEmpty()
    val planned = period?.planned(epoch).orEmpty()
    val done = planned.filter { period?.state(it.id, epoch) == HabitState.DONE }.map { it.id }.toSet()
    val pieces = period?.pieces(epoch).orEmpty()
    val drafts by remember(epoch) { store.drafts(epoch) }.collectAsState(initial = emptyList())
    val coroutines = rememberCoroutineScope()
    val context = LocalContext.current

    val recorded = entries.isNotEmpty() || done.isNotEmpty()
    val isToday = day == today
    val title = stringResource(
        when {
            ahead -> R.string.nm_mosaic_day_title_future
            isToday && !recorded -> R.string.nm_mosaic_day_title_today_empty
            isToday -> R.string.nm_mosaic_day_title_today
            recorded -> R.string.nm_mosaic_day_title_past
            else -> R.string.nm_mosaic_day_title_past_empty
        },
    )
    val caption = when {
        period == null -> null
        ahead -> stringResource(R.string.nm_mosaic_day_future_body)
        !recorded && isToday -> stringResource(R.string.nm_mosaic_day_empty_body)
        !recorded -> stringResource(R.string.nm_mosaic_day_past_empty_body)
        planned.isEmpty() -> pluralStringResource(R.plurals.nm_mosaic_entries, entries.size, entries.size)
        else -> pluralStringResource(R.plurals.nm_mosaic_entries, entries.size, entries.size) + " · " +
            stringResource(R.string.nm_mosaic_habits_done, done.size, planned.size)
    }

    Column(Modifier.fillMaxWidth()) {
        MosaicHeading(title = title, caption = caption)

        if (period != null) {
            FormRow(
                form = period.formOf(epoch),
                auto = MosaicForm.auto(epoch),
                picked = MosaicForm.of(period.info(epoch)?.form) != null,
                isToday = isToday,
                onPick = { form -> coroutines.launch { runStoreCall(context) { store.setForm(epoch, form) } } },
            )
            DayPuzzle(
                form = period.formOf(epoch),
                pieces = pieces,
                ahead = ahead,
                store = store,
                onOpenRecord = { row -> onOpenEditor(mosaicEditRoute(epoch, row.entry.habitId, row.entry.id)) },
                onOpenHabit = { habit -> onOpenEditor(mosaicEditRoute(epoch, habit.id)) },
                onAdd = { onOpenEditor(mosaicEditRoute(epoch)) },
                onCover = { row -> coroutines.launch { runStoreCall(context) { store.setCover(epoch, row.entry.id) } } },
                onDelete = { row -> onDelete(row.entry.id) },
            )
            Spacer(Modifier.height(16.dp))
        }

        if (deleted != null) {
            Surface(
                shape = RoundedCornerShape(14.dp),
                color = MuseTones.fill,
                modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp),
            ) {
                Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(start = 16.dp, end = 4.dp)) {
                    Text(
                        stringResource(R.string.nm_mosaic_deleted),
                        fontSize = 14.sp,
                        color = MaterialTheme.colorScheme.onSurface,
                        modifier = Modifier.weight(1f),
                    )
                    TextButton(onClick = onUndo) {
                        Text(stringResource(R.string.nm_mosaic_undo), color = MuseTones.action, fontWeight = FontWeight.SemiBold)
                    }
                }
            }
        }

        drafts.forEach { draft ->
            val what = draft.text.trim().takeIf { it.isNotEmpty() }
                ?: stringResource(
                    if (draft.stagedPath != null || draft.mediaId != null) R.string.nm_mosaic_draft_photo else R.string.nm_mosaic_draft_blank,
                )
            Surface(
                onClick = { onOpenEditor(mosaicEditRoute(draft.day, draft.habitId, draft.entryId, draftId = draft.id)) },
                shape = RoundedCornerShape(14.dp),
                color = MuseTones.fill,
                modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp),
            ) {
                Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.heightIn(min = 48.dp).padding(horizontal = 14.dp, vertical = 10.dp)) {
                    Icon(Icons.Outlined.EditNote, contentDescription = null, tint = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.size(20.dp))
                    Spacer(Modifier.width(10.dp))
                    Text(
                        stringResource(R.string.nm_mosaic_draft_row, what),
                        fontSize = 14.sp,
                        color = MaterialTheme.colorScheme.onSurface,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f),
                    )
                    Text(
                        stringResource(R.string.nm_mosaic_continue),
                        fontSize = 13.sp,
                        fontWeight = FontWeight.Medium,
                        color = MuseTones.action,
                        modifier = Modifier.padding(start = 8.dp),
                    )
                }
            }
        }

        if (!ahead) {
            Row(
                horizontalArrangement = Arrangement.spacedBy(10.dp),
                modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
            ) {
                WayIn(Icons.Outlined.PhotoCamera, stringResource(R.string.nm_mosaic_action_camera), Modifier.weight(1f)) {
                    onOpenEditor(mosaicEditRoute(epoch, source = MosaicEditSource.CAMERA))
                }
                WayIn(Icons.Outlined.Image, stringResource(R.string.nm_mosaic_action_album), Modifier.weight(1f)) {
                    onOpenEditor(mosaicEditRoute(epoch, source = MosaicEditSource.ALBUM))
                }
                WayIn(Icons.Outlined.ModeEdit, stringResource(R.string.nm_mosaic_action_text), Modifier.weight(1f)) {
                    onOpenEditor(mosaicEditRoute(epoch, source = MosaicEditSource.TEXT))
                }
            }
        }

        val records = pieces.filterIsInstance<DayPiece.Record>()
        if (records.isNotEmpty()) {
            RecordList(records, store) { row -> onOpenEditor(mosaicEditRoute(epoch, row.entry.habitId, row.entry.id)) }
        }

        if (period != null) {
            val separator = stringResource(R.string.nm_mosaic_list_separator)
            val habitsLine = when {
                period.habits.none { it.archivedDay == null } -> stringResource(R.string.nm_mosaic_habits_none)
                planned.isEmpty() -> stringResource(R.string.nm_mosaic_habits_none_planned)
                else -> planned.joinToString(separator) { if (it.id in done) it.title + " ✓" else it.title }
            }
            Surface(
                onClick = onOpenHabits,
                shape = RoundedCornerShape(14.dp),
                color = MuseTones.fill,
                modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
            ) {
                Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(horizontal = 14.dp, vertical = 12.dp)) {
                    Icon(Icons.Outlined.TaskAlt, contentDescription = null, tint = MaterialTheme.colorScheme.onSurface, modifier = Modifier.size(22.dp))
                    Spacer(Modifier.width(12.dp))
                    Column(Modifier.weight(1f)) {
                        Text(
                            stringResource(if (isToday) R.string.nm_mosaic_habits_today else R.string.nm_mosaic_habits_of_day),
                            fontSize = 15.sp,
                            fontWeight = FontWeight.SemiBold,
                            color = MaterialTheme.colorScheme.onSurface,
                        )
                        Text(
                            habitsLine,
                            fontSize = 12.5.sp,
                            lineHeight = 17.sp,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            maxLines = 2,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                    Text(
                        stringResource(R.string.nm_mosaic_view),
                        fontSize = 13.sp,
                        fontWeight = FontWeight.Medium,
                        color = MuseTones.action,
                        modifier = Modifier.padding(start = 8.dp),
                    )
                }
            }
        }
    }
}

/** "Today's shape: Heart" and the way to pick another one, or to go back to the automatic one. */
@Composable
private fun FormRow(form: MosaicForm, auto: MosaicForm, picked: Boolean, isToday: Boolean, onPick: (MosaicForm?) -> Unit) {
    var menu by remember { mutableStateOf(false) }
    val check: @Composable () -> Unit = { Icon(Icons.Filled.Check, contentDescription = null, modifier = Modifier.size(18.dp)) }
    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth().padding(start = 20.dp, end = 8.dp)) {
        Text(
            stringResource(if (isToday) R.string.nm_mosaic_form_today else R.string.nm_mosaic_form_day, stringResource(formLabel(form))),
            fontSize = 13.sp,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.weight(1f),
        )
        Box {
            TextButton(onClick = { menu = true }) {
                Text(stringResource(R.string.nm_mosaic_form_change), color = MuseTones.action, fontWeight = FontWeight.Medium)
            }
            DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                DropdownMenuItem(
                    text = { Text(stringResource(R.string.nm_mosaic_form_auto, stringResource(formLabel(auto)))) },
                    onClick = { menu = false; onPick(null) },
                    trailingIcon = if (!picked) check else null,
                )
                MosaicForm.entries.forEach { choice ->
                    DropdownMenuItem(
                        text = { Text(stringResource(formLabel(choice))) },
                        onClick = { menu = false; onPick(choice) },
                        trailingIcon = if (picked && choice == form) check else null,
                    )
                }
            }
        }
    }
}

/**
 * The day's shape at full size: a cloud per place, each a finger target of its own. Records show
 * their photo or their words, a planned habit its name, and the first empty place a plus; the
 * rest of the outline waits dashed. The shape grows to its large layout when the day fills up.
 */
@Composable
private fun DayPuzzle(
    form: MosaicForm,
    pieces: List<DayPiece>,
    ahead: Boolean,
    store: MosaicStore,
    onOpenRecord: (MosaicEntryRow) -> Unit,
    onOpenHabit: (MosaicHabit) -> Unit,
    onAdd: () -> Unit,
    onCover: (MosaicEntryRow) -> Unit,
    onDelete: (MosaicEntryRow) -> Unit,
) {
    val layout = remember(form, pieces.size) { PuzzleLayout(form, pieces.size) }
    BoxWithConstraints(Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 6.dp), contentAlignment = Alignment.TopCenter) {
        val unit = layout.unit(min(maxWidth, PUZZLE_MAX).value, PUZZLE_MAX.value).dp
        val d = unit * CLOUD_FILL
        Box(Modifier.size(unit * layout.width, unit * layout.height)) {
            repeat(layout.size) { i ->
                val c = layout.center(i)
                val place = Modifier.offset(x = unit * c.x - d / 2, y = unit * c.y - d / 2).size(d)
                when (val piece = pieces.getOrNull(i)) {
                    is DayPiece.Record -> key(piece.row.entry.id) {
                        RecordCloud(
                            piece = piece,
                            size = d,
                            store = store,
                            modifier = place,
                            onOpen = { onOpenRecord(piece.row) },
                            onCover = { onCover(piece.row) },
                            onDelete = { onDelete(piece.row) },
                        )
                    }
                    is DayPiece.Habit -> key("habit:" + piece.habit.id) {
                        HabitCloud(piece, d, ahead, place) { onOpenHabit(piece.habit) }
                    }
                    null -> key("empty:$i") {
                        EmptyCloud(next = i == pieces.size, ahead = ahead, size = d, modifier = place, onAdd = onAdd)
                    }
                }
            }
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun RecordCloud(
    piece: DayPiece.Record,
    size: Dp,
    store: MosaicStore,
    modifier: Modifier,
    onOpen: () -> Unit,
    onCover: () -> Unit,
    onDelete: () -> Unit,
) {
    var menu by remember { mutableStateOf(false) }
    val row = piece.row
    val editLabel = stringResource(R.string.nm_mosaic_menu_edit)
    Box(modifier) {
        Box(
            contentAlignment = Alignment.Center,
            modifier = Modifier
                .fillMaxSize()
                .clip(CloudShape)
                .background(if (row.mediaPath != null) MuseTones.fill else noteTint)
                .combinedClickable(onClickLabel = editLabel, onClick = onOpen, onLongClick = { menu = true }),
        ) {
            if (row.mediaPath != null) {
                MosaicPhoto(row, store, size, Modifier.fillMaxSize())
            } else {
                CloudLabel(row.entry.text.trim().ifEmpty { piece.habit?.title.orEmpty() }, size, MaterialTheme.colorScheme.onSurface)
            }
        }
        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
            DropdownMenuItem(text = { Text(editLabel) }, onClick = { menu = false; onOpen() })
            if (row.mediaPath != null) {
                DropdownMenuItem(text = { Text(stringResource(R.string.nm_mosaic_menu_cover)) }, onClick = { menu = false; onCover() })
            }
            DropdownMenuItem(
                text = { Text(stringResource(R.string.nm_mosaic_menu_delete), color = MaterialTheme.colorScheme.error) },
                onClick = { menu = false; onDelete() },
            )
        }
    }
}

/** A planned habit's cloud: dashed with its name while open, tinted with a tick once marked done. */
@Composable
private fun HabitCloud(piece: DayPiece.Habit, size: Dp, ahead: Boolean, modifier: Modifier, onOpen: () -> Unit) {
    val muted = MaterialTheme.colorScheme.onSurfaceVariant
    val label = stringResource(R.string.nm_mosaic_slot_add, piece.habit.title)
    Box(
        contentAlignment = Alignment.Center,
        modifier = modifier
            .then(if (piece.done) Modifier.clip(CloudShape).background(noteTint) else Modifier.dashedCloud(muted.copy(alpha = 0.5f)))
            .clip(CloudShape)
            .then(if (ahead) Modifier else Modifier.clickable(onClickLabel = label, onClick = onOpen)),
    ) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            if (size >= 40.dp) {
                Icon(
                    if (piece.done) Icons.Filled.Check else Icons.Filled.Add,
                    contentDescription = null,
                    tint = muted,
                    modifier = Modifier.size(min(20.dp, size * 0.28f)),
                )
            }
            CloudLabel(piece.habit.title, size, muted)
        }
    }
}

/** A place still empty: dashed; the first one carries a plus and opens a new record. */
@Composable
private fun EmptyCloud(next: Boolean, ahead: Boolean, size: Dp, modifier: Modifier, onAdd: () -> Unit) {
    val muted = MaterialTheme.colorScheme.onSurfaceVariant
    val label = stringResource(R.string.nm_mosaic_cloud_add)
    Box(
        contentAlignment = Alignment.Center,
        modifier = modifier
            .dashedCloud(muted.copy(alpha = if (ahead) 0.22f else if (next) 0.55f else 0.32f))
            .clip(CloudShape)
            .then(if (ahead) Modifier else Modifier.clickable(onClickLabel = label, onClick = onAdd)),
    ) {
        if (next && !ahead && size >= 32.dp) {
            Icon(Icons.Filled.Add, contentDescription = null, tint = muted, modifier = Modifier.size(min(22.dp, size * 0.32f)))
        }
    }
}

/** Words inside a cloud, as many as its size allows; none in a cloud too small to read. */
@Composable
private fun CloudLabel(text: String, size: Dp, color: androidx.compose.ui.graphics.Color) {
    if (text.isEmpty() || size < 52.dp) return
    val large = size >= 76.dp
    Text(
        text,
        fontSize = if (large) 12.sp else 10.5.sp,
        lineHeight = if (large) 15.sp else 13.sp,
        color = color,
        textAlign = TextAlign.Center,
        maxLines = if (large) 3 else 2,
        overflow = TextOverflow.Ellipsis,
        modifier = Modifier.padding(horizontal = size * 0.17f),
    )
}

/**
 * The day's records in the order they were made: what the clouds are too small to say, with the
 * time each was written, so a habit kept at a set hour shows whether it was.
 */
@Composable
private fun RecordList(records: List<DayPiece.Record>, store: MosaicStore, onOpen: (MosaicEntryRow) -> Unit) {
    val formats = rememberMosaicFormats()
    Column(Modifier.fillMaxWidth()) {
        Text(
            stringResource(R.string.nm_mosaic_records_title),
            fontSize = 15.sp,
            fontWeight = FontWeight.SemiBold,
            color = MaterialTheme.colorScheme.onSurface,
            modifier = Modifier.padding(start = 20.dp, end = 20.dp, top = 10.dp, bottom = 2.dp),
        )
        records.forEach { piece ->
            val row = piece.row
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier
                    .fillMaxWidth()
                    .clickable(onClickLabel = stringResource(R.string.nm_mosaic_menu_edit)) { onOpen(row) }
                    .heightIn(min = 56.dp)
                    .padding(horizontal = 20.dp, vertical = 6.dp),
            ) {
                Box(Modifier.size(40.dp).clip(CloudShape).background(if (row.mediaPath != null) MuseTones.fill else noteTint)) {
                    if (row.mediaPath != null) MosaicPhoto(row, store, 40.dp, Modifier.fillMaxSize())
                }
                Spacer(Modifier.width(12.dp))
                Column(Modifier.weight(1f)) {
                    Text(
                        row.entry.text.trim().ifEmpty { stringResource(R.string.nm_mosaic_record_photo) },
                        fontSize = 14.sp,
                        lineHeight = 19.sp,
                        color = MaterialTheme.colorScheme.onSurface,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                    )
                    val habitLabel = piece.habit?.let { habit -> if (piece.done) habit.title + " ✓" else habit.title }
                    Text(
                        listOfNotNull(formats.recordedAt(row.entry), habitLabel).joinToString(" · "),
                        fontSize = 12.sp,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
                // How the person felt in this record, as energy.
                row.entry.mood?.let { mood ->
                    Spacer(Modifier.width(12.dp))
                    MosaicEnergy(mood)
                }
            }
        }
    }
}

/** One of the three ways in, in the page's grey pill. */
@Composable
private fun WayIn(icon: ImageVector, label: String, modifier: Modifier = Modifier, onClick: () -> Unit) {
    Surface(onClick = onClick, shape = RoundedCornerShape(14.dp), color = MuseTones.fill, modifier = modifier.height(48.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.Center) {
            Icon(icon, contentDescription = null, tint = MaterialTheme.colorScheme.onSurface, modifier = Modifier.size(18.dp))
            Spacer(Modifier.width(6.dp))
            Text(label, fontSize = 14.sp, fontWeight = FontWeight.Medium, color = MaterialTheme.colorScheme.onSurface, maxLines = 1)
        }
    }
}

/** The day's shape never grows past this, so a sparse shape on a tablet stays a picture, not a wall. */
private val PUZZLE_MAX = 340.dp
