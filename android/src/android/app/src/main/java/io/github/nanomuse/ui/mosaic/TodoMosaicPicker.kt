package io.github.nanomuse.ui.mosaic

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.foundation.layout.*
import androidx.compose.ui.semantics.Role
import io.github.nanomuse.ui.home.MuseTones
import io.github.nanomuse.ui.todo.TodoSheet
import io.github.nanomuse.ui.todo.TodoBadge
import io.github.nanomuse.ui.todo.todoStatusColor
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Checkbox
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.openminis.app.R
import io.github.nanomuse.todo.TodoSelection
import io.github.nanomuse.todo.TodoTask
import java.time.LocalDate
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle

/** 碎片只记录用户明确选择的关联与状态，选择任务不会自动改变进度。 */
@Composable
internal fun TodoMosaicPicker(
    tasks: List<TodoTask>,
    selections: List<TodoSelection>,
    savedTitles: Map<String, String>,
    defaultCompletionDay: Long,
    enabled: Boolean,
    onChange: (List<TodoSelection>) -> Unit,
) {
    var isChoosing by remember { mutableStateOf(false) }
    var dateTaskId by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(enabled) {
        if (!enabled) { isChoosing = false; dateTaskId = null }
    }
    val byId = remember(tasks) { tasks.associateBy { it.id } }
    Surface(Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 8.dp),
        shape = RoundedCornerShape(22.dp), color = MuseTones.fill.copy(alpha = .65f),
        border = BorderStroke(1.dp, MuseTones.hairline)) {
    Column(Modifier.padding(14.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(stringResource(R.string.nm_todo_link_tasks), modifier = Modifier.weight(1f),
                style = MaterialTheme.typography.titleSmall)
            TextButton(onClick = { isChoosing = true }, enabled = enabled) {
                Text(stringResource(R.string.nm_todo_choose_tasks))
            }
        }
        selections.forEach { selection ->
            val task = byId[selection.taskId]
            TodoSelectionRow(selection, task?.title ?: savedTitles[selection.taskId].orEmpty(),
                enabled && task != null,
                onStatus = { status ->
                    onChange(selections.map { existing ->
                        if (existing.taskId != selection.taskId) existing else existing.copy(
                            requestedStatus = status,
                            expectedRevision = task?.revision ?: existing.expectedRevision,
                            completedDay = if (status == "done") existing.completedDay ?: defaultCompletionDay else null,
                        )
                    })
                },
                onDate = { dateTaskId = selection.taskId },
                onRemove = if (enabled) ({ onChange(selections.filterNot { it.taskId == selection.taskId }) }) else null,
            )
        }
    }
    }
    if (isChoosing && enabled) {
        TodoSelectionDialog(tasks, selections, { if (enabled) onChange(it) }, onDismiss = { isChoosing = false })
    }
    val dateSelection = selections.find { it.taskId == dateTaskId }
    if (dateSelection != null && enabled) {
        MosaicDatePicker(
            initial = LocalDate.ofEpochDay(dateSelection.completedDay ?: defaultCompletionDay),
            today = LocalDate.now(), latest = LocalDate.now(),
            onPick = { day ->
                onChange(selections.map { if (it.taskId == dateSelection.taskId) it.copy(completedDay = day.toEpochDay()) else it })
                dateTaskId = null
            },
            onDismiss = { dateTaskId = null },
        )
    }
}

/** 小屏和大字号使用纵向状态行，避免多枚芯片挤出可点击区域。 */
@Composable
private fun TodoSelectionRow(selection: TodoSelection, title: String, enabled: Boolean,
    onStatus: (String?) -> Unit, onDate: () -> Unit, onRemove: (() -> Unit)?) {
    var isExpanded by remember(selection.taskId) { mutableStateOf(false) }
    Surface(Modifier.fillMaxWidth().padding(vertical = 4.dp), shape = RoundedCornerShape(16.dp), color = MuseTones.surface) {
    Column(Modifier.padding(12.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(title, modifier = Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium)
            if (onRemove != null) IconButton(onClick = onRemove) { Icon(Icons.Outlined.Close, stringResource(R.string.nm_todo_unlink), Modifier.size(18.dp)) }
        }
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            Column {
                AssistChip(onClick = { isExpanded = true }, enabled = enabled,
                    label = { Text(stringResource(selectionStatusLabel(selection.requestedStatus))) },
                    trailingIcon = { Icon(Icons.Outlined.ExpandMore, null, Modifier.size(16.dp)) })
                DropdownMenu(expanded = isExpanded, onDismissRequest = { isExpanded = false }) {
                    listOf(null, "in_progress", "done").forEach { status ->
                        DropdownMenuItem(text = { Text(stringResource(selectionStatusLabel(status))) },
                            onClick = { isExpanded = false; onStatus(status) })
                    }
                }
            }
        }
        if (selection.requestedStatus == "done") {
            TextButton(onClick = onDate, enabled = enabled) {
                val date = selection.completedDay?.let { LocalDate.ofEpochDay(it)
                    .format(DateTimeFormatter.ofLocalizedDate(FormatStyle.MEDIUM)) }.orEmpty()
                Text(stringResource(R.string.nm_todo_completion_date) + ": " + date)
            }
        }
    }
}

}

/** 搜索只作用于待办文本，关联结果立即回到日记草稿的自动保存流程。 */
@Composable
private fun TodoSelectionDialog(tasks: List<TodoTask>, selections: List<TodoSelection>,
    onChange: (List<TodoSelection>) -> Unit, onDismiss: () -> Unit) {
    var query by remember { mutableStateOf("") }
    val filtered = remember(tasks, query) { tasks.filter { query.isBlank() || it.title.contains(query, true) } }
    TodoSheet(onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.nm_todo_choose_tasks)) },
        text = {
            Column {
                OutlinedTextField(query, { query = it }, singleLine = true,
                    placeholder = { Text(stringResource(R.string.nm_todo_search)) },
                    leadingIcon = { Icon(Icons.Outlined.Search, null, Modifier.size(20.dp)) },
                    shape = RoundedCornerShape(16.dp), modifier = Modifier.fillMaxWidth())
                LazyColumn(Modifier.fillMaxWidth().heightIn(max = 320.dp)) {
                    if (filtered.isEmpty()) item { Text(stringResource(R.string.nm_todo_empty), Modifier.padding(12.dp)) }
                    items(filtered, key = { it.id }) { task ->
                        val existing = selections.find { it.taskId == task.id }
                        Surface(shape = RoundedCornerShape(14.dp), color = if (existing != null) MaterialTheme.colorScheme.primary.copy(alpha = .08f) else MuseTones.surface,
                            modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp)) {
                        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth().toggleable(
                            value = existing != null, role = Role.Checkbox, onValueChange = { checked ->
                                onChange(if (checked) selections + TodoSelection(task.id, task.revision)
                                    else selections.filterNot { it.taskId == task.id })
                            })) {
                            Checkbox(checked = existing != null, onCheckedChange = null, modifier = Modifier.padding(12.dp))
                            Column(Modifier.weight(1f).padding(vertical = 8.dp)) {
                                Text(task.title)
                                Text(stringResource(when (task.status) {
                                    "done" -> R.string.nm_todo_done
                                    "in_progress" -> R.string.nm_todo_in_progress
                                    else -> R.string.nm_todo_not_started
                                }), style = MaterialTheme.typography.bodySmall)
                            }
                        }
                    }
                    }
                }
            }
        },
        dismissButton = {},
        confirmButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.nm_todo_close)) } },
    )
}

private fun selectionStatusLabel(status: String?): Int = when (status) {
    "in_progress" -> R.string.nm_todo_in_progress
    "done" -> R.string.nm_todo_done
    else -> R.string.nm_todo_link_only
}
