package io.github.nanomuse.ui.focus

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.ExpandLess
import androidx.compose.material.icons.outlined.ExpandMore
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.openminis.app.R
import io.github.nanomuse.focus.*
import io.github.nanomuse.todo.TodoTask
import io.github.nanomuse.ui.todo.TodoPeriodHeader
import io.github.nanomuse.ui.todo.todoChartColors
import io.github.nanomuse.ui.todo.todoDate
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.text.NumberFormat
import java.time.LocalDate
import java.time.format.DateTimeFormatter
import java.time.temporal.WeekFields
import java.util.Locale
import kotlin.math.atan2
import kotlin.math.hypot

/**
 * 专注统计沿用待办的分组：待办页的统计看各分组占任务的比重，这里看各分组占专注时间的比重。
 * 周期可前后翻，环图和图例共用一份结果；点开分组列出组内各任务的时长和在组内的占比。
 */
@OptIn(ExperimentalLayoutApi::class)
@Composable
internal fun FocusStats(
    rows: List<FocusSession>,
    spans: List<FocusSpan>,
    runs: List<io.github.nanomuse.focus.lock.LockRun>,
    tasks: List<TodoTask>,
) {
    var period by rememberSaveable { mutableStateOf("week") }
    var anchorDay by rememberSaveable { mutableStateOf(LocalDate.now().toEpochDay()) }
    var selectedGroup by rememberSaveable { mutableStateOf<String?>(null) }
    // 占比按待办分组还是按标签看；切换后清掉已展开的项。
    var shareBy by rememberSaveable { mutableStateOf(FocusShareBy.GROUP.name) }
    val by = FocusShareBy.valueOf(shareBy)
    val anchor = LocalDate.ofEpochDay(anchorDay)
    val start = when (period) {
        "day" -> anchor
        "week" -> anchor.with(WeekFields.of(Locale.getDefault()).dayOfWeek(), 1)
        "year" -> anchor.withDayOfYear(1)
        else -> anchor.withDayOfMonth(1)
    }
    val end = when (period) {
        "day" -> start.plusDays(1)
        "week" -> start.plusWeeks(1)
        "year" -> start.plusYears(1)
        else -> start.plusMonths(1)
    }
    // 计算放在后台线程；新结果算好之前保留上一份，切换周期时不闪回空白。
    val summary by produceState<FocusGroupSummary?>(null, rows, spans, tasks, start, end, by) {
        value = withContext(Dispatchers.Default) { FocusGroupStatistics.calculate(rows, spans, tasks, start, end, by = by) }
    }
    fun move(direction: Long) {
        val next = when (period) {
            "day" -> anchor.plusDays(direction)
            "week" -> anchor.plusWeeks(direction)
            "year" -> anchor.plusYears(direction)
            else -> anchor.plusMonths(direction)
        }
        if (next.year !in 1..9999) return
        anchorDay = next.toEpochDay()
        selectedGroup = null
    }
    val colors = todoChartColors()
    val result = summary
    Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
        FocusPanel {
            FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                listOf("day" to R.string.nm_focus_day, "week" to R.string.nm_focus_week,
                    "month" to R.string.nm_focus_month, "year" to R.string.nm_focus_year).forEach { (value, label) ->
                    FilterChip(selected = period == value, onClick = { period = value; selectedGroup = null },
                        label = { Text(stringResource(label)) }, modifier = Modifier.heightIn(min = 48.dp))
                }
            }
            TodoPeriodHeader(periodTitle(period, start, end), { move(-1) }, { move(1) })
            Text(formatFocusDuration(result?.totalMs ?: 0), style = MaterialTheme.typography.headlineLarge, fontWeight = FontWeight.SemiBold)
            if (result != null && result.sessionCount > 0) Text(
                stringResource(R.string.nm_focus_summary_count, result.sessionCount, formatFocusDuration(result.averageMs)),
                style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Text(stringResource(R.string.nm_focus_stats_hint), style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        io.github.nanomuse.ui.focus.lock.LockStatisticsContent(rows, spans, runs, start, end)
        FocusPanel {
            Text(stringResource(R.string.nm_focus_distribution), style = MaterialTheme.typography.titleMedium)
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                listOf(FocusShareBy.GROUP to R.string.nm_focus_by_group, FocusShareBy.TAG to R.string.nm_focus_by_tag).forEach { (value, label) ->
                    FilterChip(selected = by == value, onClick = { shareBy = value.name; selectedGroup = null },
                        label = { Text(stringResource(label)) }, modifier = Modifier.heightIn(min = 48.dp))
                }
            }
            Text(stringResource(if (by == FocusShareBy.TAG) R.string.nm_focus_tag_hint else R.string.nm_focus_group_hint),
                style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            when {
                result == null -> LinearProgressIndicator(Modifier.fillMaxWidth())
                result.groups.isEmpty() -> Text(stringResource(R.string.nm_focus_empty))
                else -> FocusGroupDonut(result, colors) { group -> selectedGroup = if (selectedGroup == group) null else group }
            }
        }
        if (result != null) result.groups.forEachIndexed { index, group ->
            FocusGroupRow(group, by, colors[index % colors.size], selectedGroup == group.group) {
                selectedGroup = if (selectedGroup == group.group) null else group.group
            }
        }
    }
}

/** 周期标题按区域格式缩短，周视图保留明确的起止日期。 */
private fun periodTitle(period: String, start: LocalDate, end: LocalDate): String = when (period) {
    "day" -> todoDate(start.toEpochDay())
    "month" -> start.format(DateTimeFormatter.ofPattern("LLLL yyyy", Locale.getDefault()))
    "year" -> start.format(DateTimeFormatter.ofPattern("yyyy", Locale.getDefault()))
    else -> "${todoDate(start.toEpochDay())} / ${todoDate(end.minusDays(1).toEpochDay())}"
}

@Composable
private fun groupLabel(group: String, by: FocusShareBy): String =
    group.ifBlank { stringResource(if (by == FocusShareBy.TAG) R.string.nm_todo_untagged else R.string.nm_todo_ungrouped) }

/** 环图中央显示总时长；触摸只命中环带，图例提供同样的朗读和点选入口。 */
@Composable
private fun FocusGroupDonut(summary: FocusGroupSummary, colors: List<Color>, onSelect: (String) -> Unit) {
    val currentOnSelect by rememberUpdatedState(onSelect)
    val totalLabel = formatFocusDuration(summary.totalMs)
    BoxWithConstraints(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
        val diameter = minOf(maxWidth, if (LocalDensity.current.fontScale > 1.3f) 300.dp else 236.dp)
        Box(Modifier.size(diameter), contentAlignment = Alignment.Center) {
            Canvas(Modifier.fillMaxSize().pointerInput(summary) {
                detectTapGestures { point ->
                    val center = Offset(size.width / 2f, size.height / 2f)
                    val distance = hypot(point.x - center.x, point.y - center.y)
                    val radius = minOf(size.width, size.height) * .42f
                    if (distance in (radius - 18.dp.toPx())..(radius + 18.dp.toPx())) {
                        val angle = (Math.toDegrees(atan2((point.y - center.y).toDouble(), (point.x - center.x).toDouble())) + 450) % 360
                        var boundary = 0.0
                        summary.groups.firstOrNull { group -> boundary += group.percentage * 3.6; angle < boundary }
                            ?.let { currentOnSelect(it.group) }
                    }
                }
            }) {
                val arc = size.minDimension * .84f
                val topLeft = Offset((size.width - arc) / 2, (size.height - arc) / 2)
                var startAngle = -90f
                summary.groups.forEachIndexed { index, group ->
                    val sweep = (group.percentage * 3.6).toFloat()
                    drawArc(colors[index % colors.size], startAngle, sweep, false, topLeft, Size(arc, arc), style = Stroke(24.dp.toPx()))
                    startAngle += sweep
                }
            }
            Column(Modifier.width(diameter * .58f).clearAndSetSemantics { contentDescription = totalLabel },
                horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(totalLabel, style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.SemiBold, textAlign = TextAlign.Center)
                Text(stringResource(R.string.nm_focus_total), style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant, textAlign = TextAlign.Center)
            }
        }
    }
}

/** 一个分组：占比、时长、次数和比例条；展开后列出组内任务及其在组内的占比。 */
@Composable
private fun FocusGroupRow(group: FocusGroupShare, by: FocusShareBy, color: Color, isSelected: Boolean, onClick: () -> Unit) {
    val percent = remember(Locale.getDefault()) { NumberFormat.getPercentInstance().apply { maximumFractionDigits = 1 } }
    Surface(onClick = onClick, modifier = Modifier.fillMaxWidth().semantics { selected = isSelected },
        shape = RoundedCornerShape(18.dp), color = MaterialTheme.colorScheme.surface,
        border = BorderStroke(1.dp, if (isSelected) color else MaterialTheme.colorScheme.outlineVariant.copy(alpha = .65f))) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Box(Modifier.size(10.dp).background(color, CircleShape))
                Text(groupLabel(group.group, by), Modifier.weight(1f), style = MaterialTheme.typography.titleSmall,
                    fontWeight = FontWeight.SemiBold, maxLines = 2, overflow = TextOverflow.Ellipsis)
                Text(percent.format(group.percentage / 100), style = MaterialTheme.typography.labelLarge,
                    fontWeight = FontWeight.SemiBold, color = color)
                Icon(if (isSelected) Icons.Outlined.ExpandLess else Icons.Outlined.ExpandMore, null, Modifier.size(18.dp),
                    tint = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            Text(stringResource(R.string.nm_focus_group_meta, formatFocusDuration(group.durationMs), group.sessionCount),
                style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            LinearProgressIndicator(progress = { (group.percentage / 100).toFloat().coerceIn(0f, 1f) },
                modifier = Modifier.fillMaxWidth().height(4.dp), color = color, trackColor = color.copy(alpha = .1f))
            if (isSelected) Column(Modifier.padding(top = 6.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                group.tasks.forEach { task ->
                    val share = if (group.durationMs > 0) task.durationMs.toDouble() / group.durationMs else 0.0
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        Text(task.title, Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium,
                            maxLines = 2, overflow = TextOverflow.Ellipsis)
                        Text(stringResource(R.string.nm_focus_task_share, formatFocusDuration(task.durationMs), percent.format(share)),
                            style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    LinearProgressIndicator(progress = { share.toFloat().coerceIn(0f, 1f) },
                        modifier = Modifier.fillMaxWidth().height(3.dp), color = color.copy(alpha = .7f), trackColor = color.copy(alpha = .08f))
                }
            }
        }
    }
}
