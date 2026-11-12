package io.github.nanomuse.ui.todo

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.unit.dp
import com.openminis.app.R
import io.github.nanomuse.todo.TodoTask
import io.github.nanomuse.ui.home.MuseTones
import java.time.LocalDate
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle

/** 状态仅由真实数据决定，文字与符号共同表达含义。 */
@Composable
internal fun todoStatusLabel(status: String): String = stringResource(when (status) {
    "done" -> R.string.nm_todo_done
    "in_progress" -> R.string.nm_todo_in_progress
    else -> R.string.nm_todo_not_started
})

/** 状态色在暗色模式提升亮度，避免只通过颜色传递信息。 */
@Composable
internal fun todoStatusColor(status: String): Color = when (status) {
    "done" -> if (MuseTones.isDark) Color(0xFF76D6B2) else Color(0xFF287A60)
    "in_progress" -> MaterialTheme.colorScheme.primary
    else -> MaterialTheme.colorScheme.onSurfaceVariant
}

/** 日期按用户区域显示，不把日序号误作时刻。 */
internal fun todoDate(day: Long): String = LocalDate.ofEpochDay(day)
    .format(DateTimeFormatter.ofLocalizedDate(FormatStyle.MEDIUM))

/** 共享卡片只绘制纯色和细边线，避免滚动时实时模糊的开销。 */
@Composable
internal fun TodoPanel(modifier: Modifier = Modifier, content: @Composable ColumnScope.() -> Unit) {
    Surface(modifier = modifier.fillMaxWidth(), shape = RoundedCornerShape(24.dp),
        color = MuseTones.surface, border = BorderStroke(1.dp, MuseTones.hairline.copy(alpha = .65f))) {
        Column(Modifier.padding(18.dp), verticalArrangement = Arrangement.spacedBy(14.dp), content = content)
    }
}

/** 分区标题和计数保持固定层级，数量来自当前筛选结果。 */
@Composable
internal fun TodoSectionTitle(title: String, count: Int? = null) {
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(title, Modifier.weight(1f), style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
        count?.let { Surface(shape = CircleShape, color = MuseTones.fill) {
            Text(it.toString(), Modifier.padding(horizontal = 10.dp, vertical = 4.dp),
                style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        } }
    }
}

/** 空状态保留上下文，不使用虚构数据或装饰图占据首屏。 */
@Composable
internal fun TodoEmptyState(text: String) {
    Column(Modifier.fillMaxWidth().padding(vertical = 26.dp, horizontal = 20.dp),
        horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Surface(shape = CircleShape, color = MaterialTheme.colorScheme.primary.copy(alpha = .08f)) {
            Icon(Icons.Outlined.Inbox, null, Modifier.padding(16.dp).size(26.dp), tint = MaterialTheme.colorScheme.primary)
        }
        Text(text, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = androidx.compose.ui.text.style.TextAlign.Center)
    }
}

/** 状态徽标与小标签复用相同的圆角与间距。 */
@Composable
internal fun TodoBadge(text: String, color: Color = MaterialTheme.colorScheme.onSurfaceVariant, icon: ImageVector? = null) {
    Surface(shape = RoundedCornerShape(8.dp), color = color.copy(alpha = .08f)) {
        Row(Modifier.padding(horizontal = 8.dp, vertical = 4.dp), verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(4.dp)) {
            icon?.let { Icon(it, null, Modifier.size(12.dp), tint = color) }
            Text(text, style = MaterialTheme.typography.labelSmall, color = color)
        }
    }
}

/** 任务标题优先，元数据为次级；状态入口有独立触摸区，主列表可直接完成或重开。 */
@OptIn(ExperimentalLayoutApi::class)
@Composable
internal fun TodoTaskRow(task: TodoTask, onOpen: (TodoTask) -> Unit, onToggle: (() -> Unit)? = null, isBusy: Boolean = false) {
    val tags = remember(task.tagsJson) { task.tags() }
    val statusColor = todoStatusColor(task.status)
    val statusIcon = when (task.status) {
        "done" -> Icons.Outlined.CheckCircle
        "in_progress" -> Icons.Outlined.Timelapse
        else -> Icons.Outlined.RadioButtonUnchecked
    }
    Surface(shape = RoundedCornerShape(18.dp), color = MuseTones.surface,
        border = BorderStroke(1.dp, MuseTones.hairline.copy(alpha = .65f)),
        modifier = Modifier.fillMaxWidth().clickable(role = Role.Button) { onOpen(task) }) {
        Row(Modifier.padding(start = 8.dp, end = 14.dp, top = 10.dp, bottom = 10.dp),
            verticalAlignment = Alignment.Top) {
            if (onToggle == null) Icon(statusIcon, null, Modifier.padding(12.dp).size(23.dp), tint = statusColor)
            else IconButton(onClick = onToggle, enabled = !isBusy, modifier = Modifier.size(48.dp)) {
                if (isBusy) CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp)
                else Icon(statusIcon, stringResource(if (task.status == "done") R.string.nm_todo_not_started else R.string.nm_todo_confirm_done) + ": " + task.title,
                    Modifier.size(23.dp), tint = statusColor)
            }
            Column(Modifier.weight(1f).padding(vertical = 7.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(task.title, style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold,
                    color = if (task.status == "done") MaterialTheme.colorScheme.onSurfaceVariant else MaterialTheme.colorScheme.onSurface,
                    textDecoration = if (task.status == "done") TextDecoration.LineThrough else TextDecoration.None)
                FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalArrangement = Arrangement.spacedBy(5.dp)) {
                    TodoBadge(todoStatusLabel(task.status), statusColor)
                    if (task.groupName.isNotBlank()) TodoBadge(task.groupName, icon = Icons.Outlined.Folder)
                    tags.take(3).forEach { TodoBadge(it, icon = Icons.Outlined.Tag) }
                    if (tags.size > 3) TodoBadge("+${tags.size - 3}")
                }
                val date = task.dueDay ?: task.scheduledDay
                if (date != null) {
                    val isOverdue = task.status != "done" && task.dueDay?.let { it < LocalDate.now().toEpochDay() } == true
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(5.dp)) {
                        Icon(Icons.Outlined.CalendarToday, null, Modifier.size(13.dp),
                            tint = if (isOverdue) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant)
                        Text(stringResource(if (task.dueDay != null) R.string.nm_todo_due_value else R.string.nm_todo_scheduled_value, todoDate(date)),
                            style = MaterialTheme.typography.labelSmall,
                            color = if (isOverdue) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
            }
            if (task.isImportant || task.isUrgent) Icon(Icons.Outlined.Flag,
                listOfNotNull(stringResource(R.string.nm_todo_important).takeIf { task.isImportant },
                    stringResource(R.string.nm_todo_urgent).takeIf { task.isUrgent }).joinToString(", "),
                Modifier.padding(top = 12.dp).size(17.dp), tint = if (task.isUrgent) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.primary)
        }
    }
}

/** 局部清单采用有界惰性布局，避免一次组合全部任务。 */
@Composable
internal fun TodoTaskSection(tasks: List<TodoTask>, onOpen: (TodoTask) -> Unit, empty: String) {
    if (tasks.isEmpty()) { TodoEmptyState(empty); return }
    LazyColumn(Modifier.fillMaxWidth().heightIn(max = 500.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        items(tasks, key = { it.id }, contentType = { "todo_task" }) { TodoTaskRow(it, onOpen) }
    }
}

/** 周期按钮与标题分离，长日期可自然换行。 */
@Composable
internal fun TodoPeriodHeader(title: String, onPrevious: () -> Unit, onNext: () -> Unit) {
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Text(title, Modifier.weight(1f).padding(end = 8.dp), style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
        IconButton(onClick = onPrevious) { Icon(Icons.Outlined.ChevronLeft, stringResource(R.string.nm_todo_previous)) }
        IconButton(onClick = onNext) { Icon(Icons.Outlined.ChevronRight, stringResource(R.string.nm_todo_next)) }
    }
}
