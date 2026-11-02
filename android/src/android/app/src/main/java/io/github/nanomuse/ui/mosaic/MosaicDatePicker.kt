package io.github.nanomuse.ui.mosaic

import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowLeft
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.DateRange
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.openminis.app.R
import io.github.nanomuse.mosaic.MosaicRange
import io.github.nanomuse.mosaic.MosaicStore
import io.github.nanomuse.mosaic.parseDiaryPickerDate
import java.time.DayOfWeek
import java.time.LocalDate
import java.time.format.TextStyle

/** 日记浏览和编辑共用的日期弹窗，日期数字保留红绿记录圈。 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MosaicDatePicker(initial: LocalDate, today: LocalDate, onPick: (LocalDate) -> Unit, onDismiss: () -> Unit, latest: LocalDate? = null) {
    val context = LocalContext.current
    val store = remember { MosaicStore.get(context) }
    val formats = rememberMosaicFormats()
    var selectedValue by rememberSaveable { mutableStateOf(initial.toString()) }
    var monthValue by rememberSaveable { mutableStateOf(initial.withDayOfMonth(1).toString()) }
    var input by rememberSaveable { mutableStateOf(false) }
    val selected = parseDiaryPickerDate(selectedValue, latest)
    val allowed = selected != null
    val month = LocalDate.parse(monthValue)
    DatePickerDialog(onDismissRequest = onDismiss, confirmButton = {
        TextButton(enabled = allowed, onClick = { selected?.let(onPick); onDismiss() }) { Text(stringResource(android.R.string.ok)) }
    }, dismissButton = {
        Row {
            TextButton(enabled = latest == null || !today.isAfter(latest), onClick = { onPick(today); onDismiss() }) { Text(stringResource(R.string.nm_mosaic_today)) }
            TextButton(onClick = onDismiss) { Text(stringResource(android.R.string.cancel)) }
        }
    }) {
        Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(12.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(selected?.let(formats.snippet::format) ?: stringResource(R.string.nm_calendar_date_hint),
                    style = MaterialTheme.typography.titleMedium, modifier = Modifier.weight(1f))
                IconButton(onClick = {
                    if (input && allowed) monthValue = selected!!.withDayOfMonth(1).toString()
                    input = !input
                }) { Icon(if (input) Icons.Default.DateRange else Icons.Default.Edit,
                    stringResource(if (input) R.string.nm_calendar_grid else R.string.nm_calendar_input)) }
            }
            if (input) {
                OutlinedTextField(selectedValue, { selectedValue = it }, singleLine = true,
                    label = { Text(stringResource(R.string.nm_calendar_date_hint)) }, isError = !allowed,
                    supportingText = { if (!allowed) Text(stringResource(R.string.nm_calendar_invalid)) },
                    modifier = Modifier.fillMaxWidth())
            } else {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    IconButton(enabled = month > LocalDate.of(1, 1, 1), onClick = { monthValue = month.minusMonths(1).toString() }) {
                        Icon(Icons.AutoMirrored.Filled.KeyboardArrowLeft, stringResource(R.string.nm_mosaic_previous))
                    }
                    Text(formats.yearMonth.format(month), Modifier.weight(1f).clickable { input = true },
                        style = MaterialTheme.typography.titleMedium)
                    IconButton(enabled = month < LocalDate.of(9999, 12, 1), onClick = { monthValue = month.plusMonths(1).toString() }) {
                        Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, stringResource(R.string.nm_mosaic_next))
                    }
                }
                // 切月重建订阅，尚未返回的新月份不能沿用旧月份的空值画红圈。
                key(monthValue) {
                    RecordPickerMonth(store, month, selected, today, latest) { selectedValue = it.toString() }
                }
                MosaicRecordLegend()
            }
        }
    }
}

@Composable
private fun RecordPickerMonth(store: MosaicStore, first: LocalDate, selected: LocalDate?, today: LocalDate, latest: LocalDate?, onSelect: (LocalDate) -> Unit) {
    val range = remember(first) { MosaicRange(first, first.plusMonths(1)) }
    val rows by remember(range) { store.recordCounts(range) }.collectAsState(initial = null)
    val counts = remember(rows) { rows?.associate { it.day to it.entryCount } }
    val locale = LocalContext.current.resources.configuration.locales[0]
    val leading = first.dayOfWeek.value - 1
    val length = first.lengthOfMonth()
    Column {
        Row {
            DayOfWeek.entries.forEach { day ->
                Box(Modifier.weight(1f).height(28.dp), contentAlignment = Alignment.Center) {
                    Text(day.getDisplayName(TextStyle.NARROW, locale), style = MaterialTheme.typography.labelMedium)
                }
            }
        }
        repeat((leading + length + 6) / 7) { week ->
            Row(horizontalArrangement = Arrangement.spacedBy(2.dp)) {
                repeat(7) { weekday ->
                    val offset = week * 7 + weekday - leading
                    val date = first.plusDays(offset.toLong())
                    val enabled = offset in 0 until length && (latest == null || !date.isAfter(latest))
                    val outline = when (date) { selected -> 2.dp; today -> 1.dp; else -> 0.dp }
                    val shape = RoundedCornerShape(8.dp)
                    Box(Modifier.weight(1f).aspectRatio(1f).padding(1.dp).clip(shape)
                        .then(if (outline.value > 0 && offset in 0 until length) Modifier.border(outline, MaterialTheme.colorScheme.onSurface, shape) else Modifier)
                        .clickable(enabled = enabled) { onSelect(date) }, contentAlignment = Alignment.Center) {
                        if (offset in 0 until length) MosaicDateNumber(date.toEpochDay(), today.toEpochDay(), counts?.get(date.toEpochDay()) ?: if (counts == null) null else 0)
                    }
                }
            }
        }
    }
}
