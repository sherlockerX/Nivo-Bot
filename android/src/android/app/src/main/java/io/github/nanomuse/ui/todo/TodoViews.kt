package io.github.nanomuse.ui.todo

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.openminis.app.R
import io.github.nanomuse.todo.TodoTask
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.time.DayOfWeek
import java.time.LocalDate
import java.time.YearMonth
import java.time.format.DateTimeFormatter
import java.time.format.TextStyle
import java.time.temporal.WeekFields
import java.util.Locale

/** 一次构建日期索引，同一天既计划又截止的任务只出现一次。 */
private data class TodoCalendarData(val byDay: Map<Long, List<TodoTask>>, val undated: List<TodoTask>)

/** 日期索引在后台构建，界面只读取当前日期的任务。 */
private fun calendarData(tasks: List<TodoTask>): TodoCalendarData {
    val byDay = linkedMapOf<Long, MutableList<TodoTask>>()
    tasks.forEach { task ->
        listOfNotNull(task.scheduledDay, task.dueDay).distinct().forEach { day ->
            byDay.getOrPut(day) { mutableListOf() }.add(task)
        }
    }
    return TodoCalendarData(byDay, tasks.filter { it.scheduledDay == null && it.dueDay == null })
}

/** 日历与所选日期保持一致，窄屏和大字号切换为可滚动日期条。 */
@Composable
internal fun TodoCalendar(tasks: List<TodoTask>, onOpen: (TodoTask) -> Unit) {
    var monthValue by rememberSaveable { mutableStateOf(YearMonth.now().toString()) }
    var selectedDay by rememberSaveable { mutableStateOf(LocalDate.now().toEpochDay()) }
    val month = YearMonth.parse(monthValue)
    val locale = Locale.getDefault()
    val firstWeekday = WeekFields.of(locale).firstDayOfWeek
    val indexed by produceState<TodoCalendarData?>(null, tasks) {
        value = null
        value = withContext(Dispatchers.Default) { calendarData(tasks) }
    }
    val current = indexed
    fun moveMonth(direction: Long) {
        val nextMonth = month.plusMonths(direction)
        if (nextMonth.year !in 1..9999) return
        val nextDay = LocalDate.ofEpochDay(selectedDay).dayOfMonth.coerceAtMost(nextMonth.lengthOfMonth())
        monthValue = nextMonth.toString()
        selectedDay = nextMonth.atDay(nextDay).toEpochDay()
    }
    Column(verticalArrangement = Arrangement.spacedBy(18.dp)) {
        TodoPanel {
            TodoPeriodHeader(month.format(DateTimeFormatter.ofPattern("LLLL yyyy", locale)),
                { moveMonth(-1) }, { moveMonth(1) })
            BoxWithConstraints(Modifier.fillMaxWidth()) {
                val fontScale = LocalDensity.current.fontScale
                if (maxWidth >= 336.dp && fontScale <= 1.3f) {
                    TodoMonthGrid(month, firstWeekday, selectedDay, current?.byDay.orEmpty()) { selectedDay = it }
                } else {
                    TodoCalendarAgenda(month, selectedDay, current?.byDay.orEmpty()) { selectedDay = it }
                }
            }
            TextButton(onClick = {
                val today = LocalDate.now()
                monthValue = YearMonth.from(today).toString()
                selectedDay = today.toEpochDay()
            }, modifier = Modifier.align(Alignment.End).heightIn(min = 48.dp)) {
                Icon(Icons.Outlined.Today, null, Modifier.size(18.dp))
                Spacer(Modifier.width(6.dp))
                Text(stringResource(R.string.nm_profile_today))
            }
        }
        if (current == null) LinearProgressIndicator(Modifier.fillMaxWidth())
        else {
            val dayTasks = current.byDay[selectedDay].orEmpty()
            TodoSectionTitle(todoDate(selectedDay), dayTasks.size)
            TodoTaskSection(dayTasks, onOpen, stringResource(R.string.nm_todo_no_day_tasks))
            TodoSectionTitle(stringResource(R.string.nm_todo_unscheduled), current.undated.size)
            TodoTaskSection(current.undated, onOpen, stringResource(R.string.nm_todo_empty))
        }
    }
}

/** 月网格按当地周起点排列，空白单元格不参与交互。 */
@Composable
private fun TodoMonthGrid(
    month: YearMonth,
    firstWeekday: DayOfWeek,
    selectedDay: Long,
    byDay: Map<Long, List<TodoTask>>,
    onSelect: (Long) -> Unit,
) {
    val locale = Locale.getDefault()
    val cells = remember(month, firstWeekday) {
        val offset = (month.atDay(1).dayOfWeek.value - firstWeekday.value + 7) % 7
        (0 until offset + month.lengthOfMonth()).map { index ->
            if (index < offset) null else month.atDay(index - offset + 1)
        }.chunked(7)
    }
    Column(verticalArrangement = Arrangement.spacedBy(5.dp)) {
        Row(Modifier.fillMaxWidth()) {
            (0..6).forEach { index ->
                Text(DayOfWeek.of((firstWeekday.value - 1 + index) % 7 + 1)
                    .getDisplayName(TextStyle.SHORT, locale),
                    Modifier.weight(1f).padding(vertical = 6.dp), textAlign = TextAlign.Center,
                    style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
        cells.forEach { week ->
            Row(Modifier.fillMaxWidth()) {
                (0..6).forEach { index ->
                    val date = week.getOrNull(index)
                    if (date == null) Spacer(Modifier.weight(1f).height(48.dp))
                    else TodoDayCell(date, selectedDay, byDay[date.toEpochDay()].orEmpty().size,
                        Modifier.weight(1f), false, onSelect)
                }
            }
        }
    }
}

/** 日期条始终把选择日滚入视野，大字号不挤压七列文字。 */
@Composable
private fun TodoCalendarAgenda(
    month: YearMonth,
    selectedDay: Long,
    byDay: Map<Long, List<TodoTask>>,
    onSelect: (Long) -> Unit,
) {
    val listState = rememberLazyListState()
    val dates = remember(month) { (1..month.lengthOfMonth()).map(month::atDay) }
    LaunchedEffect(month, selectedDay) {
        listState.animateScrollToItem((LocalDate.ofEpochDay(selectedDay).dayOfMonth - 2).coerceAtLeast(0))
    }
    LazyRow(state = listState, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        items(dates, key = { it.toEpochDay() }) { date ->
            TodoDayCell(date, selectedDay, byDay[date.toEpochDay()].orEmpty().size, Modifier.width(76.dp), true, onSelect)
        }
    }
}

/** 日期由选择色、今日边框和任务圆点分别表达状态。 */
@Composable
private fun TodoDayCell(
    date: LocalDate,
    selectedDay: Long,
    taskCount: Int,
    modifier: Modifier,
    showWeekday: Boolean,
    onSelect: (Long) -> Unit,
) {
    val isSelected = selectedDay == date.toEpochDay()
    val isToday = date == LocalDate.now()
    val dateLabel = stringResource(R.string.nm_todo_group_count, todoDate(date.toEpochDay()), taskCount)
    val foreground = if (isSelected) MaterialTheme.colorScheme.onPrimary else MaterialTheme.colorScheme.onSurface
    Surface(onClick = { onSelect(date.toEpochDay()) }, shape = RoundedCornerShape(14.dp),
        color = if (isSelected) MaterialTheme.colorScheme.primary else Color.Transparent,
        border = if (isToday && !isSelected) BorderStroke(1.dp, MaterialTheme.colorScheme.primary) else null,
        contentColor = foreground,
        modifier = modifier.heightIn(min = 48.dp).semantics {
            contentDescription = dateLabel
            selected = isSelected
        }) {
        Column(Modifier.padding(horizontal = 4.dp, vertical = 8.dp), horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(4.dp)) {
            if (showWeekday) Text(date.dayOfWeek.getDisplayName(TextStyle.SHORT, Locale.getDefault()),
                style = MaterialTheme.typography.labelSmall, textAlign = TextAlign.Center)
            Text(date.dayOfMonth.toString(), style = MaterialTheme.typography.bodyMedium,
                fontWeight = if (isSelected || isToday) FontWeight.Bold else FontWeight.Normal)
            Box(Modifier.size(4.dp).background(if (taskCount > 0) foreground else Color.Transparent, CircleShape))
        }
    }
}

/** 四象限先呈现摘要，所选任务独立成列以保留阅读宽度。 */
@Composable
internal fun TodoQuadrants(tasks: List<TodoTask>, onOpen: (TodoTask) -> Unit) {
    var selectedQuadrant by rememberSaveable { mutableStateOf(0) }
    val labels = listOf(R.string.nm_todo_q1, R.string.nm_todo_q2, R.string.nm_todo_q3, R.string.nm_todo_q4)
    val icons = listOf(Icons.Outlined.Flag, Icons.Outlined.StarOutline, Icons.Outlined.Schedule, Icons.Outlined.MoreHoriz)
    val colors = listOf(MaterialTheme.colorScheme.error, MaterialTheme.colorScheme.primary,
        MaterialTheme.colorScheme.tertiary, MaterialTheme.colorScheme.secondary)
    val subsets = remember(tasks) { listOf(tasks.filter { it.isImportant && it.isUrgent }, tasks.filter { it.isImportant && !it.isUrgent },
        tasks.filter { !it.isImportant && it.isUrgent }, tasks.filter { !it.isImportant && !it.isUrgent }) }
    Column(verticalArrangement = Arrangement.spacedBy(18.dp)) {
        BoxWithConstraints {
            val columns = if (maxWidth / LocalDensity.current.fontScale >= 300.dp) 2 else 1
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                (0..3).chunked(columns).forEach { row ->
                    Row(Modifier.fillMaxWidth().height(IntrinsicSize.Min), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        row.forEach { index ->
                            TodoViewSummary(stringResource(labels[index]), subsets[index].size, icons[index], colors[index],
                                selectedQuadrant == index, { selectedQuadrant = index }, Modifier.weight(1f).fillMaxHeight())
                        }
                    }
                }
            }
        }
        TodoSectionTitle(stringResource(labels[selectedQuadrant]), subsets[selectedQuadrant].size)
        TodoTaskSection(subsets[selectedQuadrant], onOpen, stringResource(R.string.nm_todo_empty))
    }
}

/** 摘要卡使用相同触摸区和字阶，颜色之外保留完整文字。 */
@Composable
private fun TodoViewSummary(
    title: String,
    count: Int,
    icon: ImageVector,
    color: Color,
    isSelected: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Surface(onClick = onClick, modifier = modifier.heightIn(min = 130.dp).semantics { selected = isSelected },
        shape = RoundedCornerShape(20.dp), color = color.copy(alpha = if (isSelected) .12f else .04f),
        border = BorderStroke(1.dp, color.copy(alpha = if (isSelected) .55f else .15f))) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.SpaceBetween) {
                Icon(icon, null, Modifier.size(22.dp), tint = color)
                Text(count.toString(), style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.SemiBold, color = color)
            }
            Text(title, style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold)
        }
    }
}

/** 分组用文件夹摘要显示真实进度，初次进入即展开首个分组。 */
@Composable
internal fun TodoGroups(tasks: List<TodoTask>, savedGroups: List<String> = emptyList(), onOpen: (TodoTask) -> Unit) {
    var selectedGroup by rememberSaveable { mutableStateOf<String?>(null) }
    val groups = remember(tasks, savedGroups) { tasks.groupBy { it.groupName }.toSortedMap().apply { savedGroups.forEach { putIfAbsent(it, emptyList()) } } }
    val activeGroup = selectedGroup?.takeIf(groups::containsKey) ?: groups.keys.firstOrNull()
    if (activeGroup == null) {
        TodoEmptyState(stringResource(R.string.nm_todo_empty))
        return
    }
    val groupLabel = activeGroup.ifBlank { stringResource(R.string.nm_todo_ungrouped) }
    Column(verticalArrangement = Arrangement.spacedBy(18.dp)) {
        BoxWithConstraints(Modifier.fillMaxWidth()) {
            val cardWidth = minOf(maxWidth, 248.dp * LocalDensity.current.fontScale.coerceAtMost(1.5f))
            LazyRow(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                items(groups.entries.toList(), key = { it.key }) { (group, values) ->
                    TodoGroupCard(group.ifBlank { stringResource(R.string.nm_todo_ungrouped) }, values,
                        group == activeGroup, { selectedGroup = group }, Modifier.width(cardWidth))
                }
            }
        }
        TodoSectionTitle(groupLabel, groups[activeGroup].orEmpty().size)
        TodoTaskSection(groups[activeGroup].orEmpty(), onOpen, stringResource(R.string.nm_todo_empty))
    }
}

/** 分组完成比例由当前任务状态计算，不混用标签统计权重。 */
@Composable
private fun TodoGroupCard(title: String, tasks: List<TodoTask>, isSelected: Boolean, onClick: () -> Unit, modifier: Modifier) {
    val completedCount = tasks.count { it.status == "done" }
    val progress = if (tasks.isEmpty()) 0f else completedCount.toFloat() / tasks.size
    val color = MaterialTheme.colorScheme.primary
    Surface(onClick = onClick, modifier = modifier.semantics { selected = isSelected }, shape = RoundedCornerShape(20.dp),
        color = if (isSelected) color.copy(alpha = .09f) else MaterialTheme.colorScheme.surface,
        border = BorderStroke(1.dp, if (isSelected) color.copy(alpha = .5f) else MaterialTheme.colorScheme.outlineVariant)) {
        Column(Modifier.padding(18.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Icon(Icons.Outlined.Folder, null, Modifier.size(24.dp), tint = color)
                Text(tasks.size.toString(), Modifier.weight(1f), style = MaterialTheme.typography.titleMedium,
                    textAlign = TextAlign.End, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            Text(title, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
            LinearProgressIndicator(progress = { progress }, modifier = Modifier.fillMaxWidth().height(4.dp),
                color = color, trackColor = color.copy(alpha = .1f))
            Text(stringResource(R.string.nm_todo_completed_count, completedCount), style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

/** 状态筛选紧凑排列，图标、文字和数量共同标明含义。 */
@OptIn(ExperimentalLayoutApi::class)
@Composable
internal fun TodoStatuses(tasks: List<TodoTask>, onOpen: (TodoTask) -> Unit) {
    var selectedStatus by rememberSaveable { mutableStateOf("todo") }
    val statuses = listOf("todo", "in_progress", "done")
    val subsets = remember(tasks) { tasks.groupBy { it.status } }
    Column(verticalArrangement = Arrangement.spacedBy(18.dp)) {
        FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            statuses.forEach { status ->
                val icon = when (status) {
                    "done" -> Icons.Outlined.CheckCircle
                    "in_progress" -> Icons.Outlined.Timelapse
                    else -> Icons.Outlined.RadioButtonUnchecked
                }
                FilterChip(selected = status == selectedStatus, onClick = { selectedStatus = status },
                    label = { Text(stringResource(R.string.nm_todo_group_count, todoStatusLabel(status), subsets[status].orEmpty().size)) },
                    leadingIcon = { Icon(icon, null, Modifier.size(18.dp), tint = todoStatusColor(status)) },
                    modifier = Modifier.heightIn(min = 48.dp))
            }
        }
        TodoSectionTitle(todoStatusLabel(selectedStatus), subsets[selectedStatus].orEmpty().size)
        TodoTaskSection(subsets[selectedStatus].orEmpty(), onOpen, stringResource(R.string.nm_todo_empty))
    }
}
