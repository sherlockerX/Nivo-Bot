package io.github.nanomuse.ui.todo

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.ChevronRight
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.openminis.app.R
import io.github.nanomuse.todo.TodoStatistics
import io.github.nanomuse.todo.TodoStatisticsResult
import io.github.nanomuse.todo.TodoTagSlice
import io.github.nanomuse.todo.TodoTask
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.text.NumberFormat
import java.time.LocalDate
import java.time.format.DateTimeFormatter
import java.time.temporal.WeekFields
import java.util.Locale
import kotlin.math.atan2
import kotlin.math.hypot

/** 完成统计仍基于完成时标签快照，图例提供与环图等价的可访问下钻。 */
@OptIn(ExperimentalLayoutApi::class)
@Composable
internal fun TodoStatisticsView(tasks: List<TodoTask>, onOpen: (TodoTask) -> Unit) {
    var period by rememberSaveable { mutableStateOf("month") }
    var anchorDay by rememberSaveable { mutableStateOf(LocalDate.now().toEpochDay()) }
    var selectedTag by rememberSaveable { mutableStateOf<String?>(null) }
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
    val calculation by produceState<TodoStatisticsResult?>(null, tasks, start, end) {
        value = null
        value = withContext(Dispatchers.Default) { TodoStatistics.calculate(tasks, start.toEpochDay(), end.toEpochDay()) }
    }
    val result = calculation
    val colors = todoChartColors()
    fun move(direction: Long) {
        val nextAnchor = when (period) {
            "day" -> anchor.plusDays(direction)
            "week" -> anchor.plusWeeks(direction)
            "year" -> anchor.plusYears(direction)
            else -> anchor.plusMonths(direction)
        }
        if (nextAnchor.year !in 1..9999) return
        anchorDay = nextAnchor.toEpochDay()
        selectedTag = null
    }
    val selectTag: (String) -> Unit = { selectedTag = if (selectedTag == it) null else it }
    Column(verticalArrangement = Arrangement.spacedBy(18.dp)) {
        TodoPanel {
            FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                listOf("day" to R.string.nm_todo_day, "week" to R.string.nm_todo_week,
                    "month" to R.string.nm_todo_month, "year" to R.string.nm_todo_year).forEach { (value, label) ->
                    FilterChip(selected = period == value, onClick = { period = value; selectedTag = null },
                        label = { Text(stringResource(label)) }, modifier = Modifier.heightIn(min = 48.dp))
                }
            }
            TodoPeriodHeader(statisticsPeriodTitle(period, start, end), { move(-1) }, { move(1) })
            if (result == null) LinearProgressIndicator(Modifier.fillMaxWidth())
            else if (result.completedCount == 0) TodoEmptyState(stringResource(R.string.nm_todo_no_completions))
            else TodoDonut(result.slices, colors, result.completedCount, selectTag)
            Text(stringResource(R.string.nm_todo_stats_notice), style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        if (result != null && result.completedCount > 0) {
            TodoStatisticsLegend(result.slices, colors, selectedTag, tasks, selectTag, onOpen)
        }
    }
}

/** 周期标题按区域格式缩短，周视图仍保留明确的起止日期。 */
private fun statisticsPeriodTitle(period: String, start: LocalDate, end: LocalDate): String = when (period) {
    "day" -> todoDate(start.toEpochDay())
    "month" -> start.format(DateTimeFormatter.ofPattern("LLLL yyyy", Locale.getDefault()))
    "year" -> start.format(DateTimeFormatter.ofPattern("yyyy", Locale.getDefault()))
    else -> "${todoDate(start.toEpochDay())} / ${todoDate(end.minusDays(1).toEpochDay())}"
}

/** 深色背景提高图表色亮度，标签始终同时保留名称和百分比。 */
@Composable
private fun todoChartColors(): List<Color> {
    val primary = MaterialTheme.colorScheme.primary
    return if (MaterialTheme.colorScheme.surface.luminance() < .5f) {
        listOf(primary, Color(0xFFC4B5FD), Color(0xFF5EEAD4), Color(0xFFFDBA74),
            Color(0xFFF9A8D4), Color(0xFFA3E635), Color(0xFF93C5FD))
    } else {
        listOf(primary, Color(0xFF7C3AED), Color(0xFF0F766E), Color(0xFFB45309),
            Color(0xFFBE185D), Color(0xFF4D7C0F), Color(0xFF0369A1))
    }
}

/** 标签任务紧随所选图例展开，避免下钻结果被长图例隔开。 */
@Composable
private fun TodoStatisticsLegend(
    slices: List<TodoTagSlice>,
    colors: List<Color>,
    selectedTag: String?,
    tasks: List<TodoTask>,
    onSelect: (String) -> Unit,
    onOpen: (TodoTask) -> Unit,
) {
    val taskById = remember(tasks) { tasks.associateBy { it.id } }
    val percent = remember(Locale.getDefault()) { NumberFormat.getPercentInstance().apply { maximumFractionDigits = 1 } }
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        slices.forEachIndexed { index, slice ->
            val isSelected = selectedTag == slice.tag
            val label = slice.tag.ifBlank { stringResource(R.string.nm_todo_untagged) }
            TodoTagLegendRow(slice, label, percent.format(slice.percentage / 100), colors[index % colors.size],
                isSelected, { onSelect(slice.tag) })
            if (isSelected) {
                val matching = remember(taskById, slice.taskIds) { slice.taskIds.mapNotNull(taskById::get) }
                Column(Modifier.padding(top = 4.dp, bottom = 12.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    TodoSectionTitle(label, matching.size)
                    TodoTaskSection(matching, onOpen, stringResource(R.string.nm_todo_empty))
                }
            }
        }
    }
}

/** 图例整行可点选，比例条与文本共用同一份统计结果。 */
@Composable
private fun TodoTagLegendRow(
    slice: TodoTagSlice,
    label: String,
    percentage: String,
    color: Color,
    isSelected: Boolean,
    onClick: () -> Unit,
) {
    Surface(onClick = onClick, modifier = Modifier.fillMaxWidth().semantics { selected = isSelected },
        shape = RoundedCornerShape(18.dp), color = MaterialTheme.colorScheme.surface,
        border = BorderStroke(1.dp, if (isSelected) color else MaterialTheme.colorScheme.outlineVariant.copy(alpha = .65f))) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Box(Modifier.size(10.dp).background(color, CircleShape))
                Text(label, Modifier.weight(1f), style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold)
                Text(percentage, style = MaterialTheme.typography.labelLarge, fontWeight = FontWeight.SemiBold, color = color)
                Icon(Icons.Outlined.ChevronRight, null, Modifier.size(18.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            Text(stringResource(R.string.nm_todo_tag_share, percentage, slice.taskCount),
                style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            LinearProgressIndicator(progress = { (slice.percentage / 100).toFloat().coerceIn(0f, 1f) },
                modifier = Modifier.fillMaxWidth().height(4.dp), color = color, trackColor = color.copy(alpha = .1f))
        }
    }
}

/** 环图中央显示真实完成任务数，触摸命中仅限环带且由图例提供朗读入口。 */
@Composable
private fun TodoDonut(slices: List<TodoTagSlice>, colors: List<Color>, completedCount: Int, onSelect: (String) -> Unit) {
    val totalLabel = stringResource(R.string.nm_todo_completed_count, completedCount)
    val currentOnSelect by rememberUpdatedState(onSelect)
    val number = remember(completedCount, Locale.getDefault()) { NumberFormat.getIntegerInstance().format(completedCount) }
    BoxWithConstraints(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
        val diameter = minOf(maxWidth, if (LocalDensity.current.fontScale > 1.3f) 300.dp else 236.dp)
        Box(Modifier.size(diameter), contentAlignment = Alignment.Center) {
            Canvas(Modifier.fillMaxSize().pointerInput(slices) {
                detectTapGestures { point ->
                    val center = Offset(size.width / 2f, size.height / 2f)
                    val distance = hypot(point.x - center.x, point.y - center.y)
                    val radius = minOf(size.width, size.height) * .42f
                    if (distance in (radius - 18.dp.toPx())..(radius + 18.dp.toPx())) {
                        val angle = (Math.toDegrees(atan2((point.y - center.y).toDouble(), (point.x - center.x).toDouble())) + 450) % 360
                        var boundary = 0.0
                        slices.firstOrNull { slice -> boundary += slice.percentage * 3.6; angle < boundary }
                            ?.let { currentOnSelect(it.tag) }
                    }
                }
            }) {
                val arcDiameter = size.minDimension * .84f
                val topLeft = Offset((size.width - arcDiameter) / 2, (size.height - arcDiameter) / 2)
                var startAngle = -90f
                slices.forEachIndexed { index, slice ->
                    val sweepAngle = (slice.percentage * 3.6).toFloat()
                    drawArc(colors[index % colors.size], startAngle, sweepAngle, false, topLeft,
                        Size(arcDiameter, arcDiameter), style = Stroke(24.dp.toPx()))
                    startAngle += sweepAngle
                }
            }
            Column(Modifier.width(diameter * .55f).clearAndSetSemantics { contentDescription = totalLabel },
                horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(number, style = MaterialTheme.typography.headlineLarge, fontWeight = FontWeight.SemiBold,
                    textAlign = TextAlign.Center)
                Text(stringResource(R.string.nm_todo_done), style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant, textAlign = TextAlign.Center)
            }
        }
    }
}
