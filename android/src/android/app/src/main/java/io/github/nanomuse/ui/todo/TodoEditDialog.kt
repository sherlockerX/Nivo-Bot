package io.github.nanomuse.ui.todo

import androidx.compose.foundation.clickable
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.foundation.shape.RoundedCornerShape
import io.github.nanomuse.ui.home.MuseTones
import java.time.ZoneOffset
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.openminis.app.R
import io.github.nanomuse.todo.TodoStore
import io.github.nanomuse.todo.TodoTask
import io.github.nanomuse.todo.todoTagsJson
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch
import java.time.LocalDate
import java.util.UUID

/** 编辑保留打开时的修订号，冲突或保存失败时不清空用户文字。 */
@Composable
internal fun TodoEditDialog(task: TodoTask, store: TodoStore, onDismiss: () -> Unit, onSaved: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var title by rememberSaveable(task.id) { mutableStateOf(task.title) }
    var notes by rememberSaveable(task.id) { mutableStateOf(task.notes) }
    var group by rememberSaveable(task.id) { mutableStateOf(task.groupName) }
    var tags by rememberSaveable(task.id) { mutableStateOf(task.tags()) }
    var categoryKind by rememberSaveable { mutableStateOf<String?>(null) }
    var scheduled by rememberSaveable(task.id) { mutableStateOf(task.scheduledDay?.let { LocalDate.ofEpochDay(it).toString() }.orEmpty()) }
    var due by rememberSaveable(task.id) { mutableStateOf(task.dueDay?.let { LocalDate.ofEpochDay(it).toString() }.orEmpty()) }
    var isImportant by rememberSaveable(task.id) { mutableStateOf(task.isImportant) }
    var isUrgent by rememberSaveable(task.id) { mutableStateOf(task.isUrgent) }
    var isSaving by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var attempted by remember { mutableStateOf<TodoTask?>(null) }
    var operationId by rememberSaveable(task.id) { mutableStateOf(UUID.randomUUID().toString()) }
    TodoSheet(onDismissRequest = { if (!isSaving) onDismiss() },
        title = { Text(stringResource(if (task.id.isEmpty()) R.string.nm_todo_new_task else R.string.nm_todo_edit_task)) },
        text = {
            Column(Modifier.fillMaxWidth(),
                verticalArrangement = Arrangement.spacedBy(12.dp)) {
                TodoPanel {
                OutlinedTextField(title, { title = it.take(500) }, label = { Text(stringResource(R.string.nm_todo_task_title)) },
                    modifier = Modifier.fillMaxWidth(), shape = RoundedCornerShape(14.dp), enabled = !isSaving)
                OutlinedTextField(notes, { notes = it }, label = { Text(stringResource(R.string.nm_todo_notes)) },
                    modifier = Modifier.fillMaxWidth(), minLines = 3, shape = RoundedCornerShape(14.dp), enabled = !isSaving)
                }
                TodoPanel {
                TodoSectionTitle(stringResource(R.string.nm_todo_calendar))
                TodoDateField(scheduled, { scheduled = it }, stringResource(R.string.nm_todo_scheduled), !isSaving)
                TodoDateField(due, { due = it }, stringResource(R.string.nm_todo_due), !isSaving)
                }
                TodoPanel {
                TodoSectionTitle(stringResource(R.string.nm_todo_groups))
                TodoCategoryFields(group, tags, !isSaving) { categoryKind = it }

                }
                TodoPanel {
                TodoToggle(isImportant, { isImportant = it }, stringResource(R.string.nm_todo_important), !isSaving)
                TodoToggle(isUrgent, { isUrgent = it }, stringResource(R.string.nm_todo_urgent), !isSaving)
                Text(stringResource(R.string.nm_todo_urgency_notice), style = MaterialTheme.typography.bodySmall)
                }
                if (task.id.isNotEmpty()) Text(stringResource(R.string.nm_todo_snapshot_notice), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
            }
        }, confirmButton = {
            Button(shape = RoundedCornerShape(14.dp), contentPadding = PaddingValues(horizontal = 28.dp, vertical = 12.dp), enabled = title.isNotBlank() && !isSaving, onClick = {
                val updated = try {
                    task.copy(title = title, notes = notes, groupName = group,
                        tagsJson = todoTagsJson(tags), scheduledDay = parseTodoDate(scheduled),
                        dueDay = parseTodoDate(due), isImportant = isImportant, isUrgent = isUrgent)
                } catch (_: Exception) { error = context.getString(R.string.nm_todo_invalid_date); return@Button }
                if (attempted != null && attempted != updated) operationId = UUID.randomUUID().toString()
                attempted = updated
                isSaving = true
                error = null
                scope.launch {
                    try { store.saveTask(updated, operationId); onSaved() }
                    catch (cancelled: CancellationException) { throw cancelled }
                    catch (_: Exception) { error = context.getString(R.string.nm_todo_save_failed) }
                    finally { isSaving = false }
                }
            }) { Text(stringResource(R.string.nm_todo_save)) }
        }, dismissButton = { TextButton(enabled = !isSaving, onClick = onDismiss) { Text(stringResource(R.string.nm_todo_cancel)) } })
    categoryKind?.let { kind ->
        TodoCategoryPicker(store, kind, if (kind == "group") listOf(group).filter { it.isNotBlank() } else tags,
            onSelection = { values -> if (kind == "group") group = values.firstOrNull().orEmpty() else tags = values },
            onDismiss = { categoryKind = null })
    }
}

/** 空日期表示不安排，输入严格使用公历日期。 */
internal fun parseTodoDate(text: String): Long? = text.trim().takeIf { it.isNotEmpty() }?.let {
    LocalDate.parse(it).also { date -> require(date.year in 1..9999) }.toEpochDay()
}

/** 日期默认通过原生日历选择；手动输入由日历切换提供，清除日期不生成假日期。 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun TodoDateField(value: String, onChange: (String) -> Unit, label: String, enabled: Boolean = true) {
    var isOpen by remember { mutableStateOf(false) }
    val parsed = remember(value) { runCatching { parseTodoDate(value) }.getOrNull() }
    Surface(onClick = { isOpen = true }, enabled = enabled, shape = RoundedCornerShape(14.dp), color = MuseTones.fill) {
        Row(Modifier.fillMaxWidth().padding(start = 14.dp, end = 6.dp, top = 8.dp, bottom = 8.dp),
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Icon(Icons.Outlined.CalendarToday, null, Modifier.size(20.dp), tint = MaterialTheme.colorScheme.primary)
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                Text(label, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                Text(parsed?.let(::todoDate) ?: stringResource(R.string.nm_todo_unscheduled), style = MaterialTheme.typography.bodyMedium)
            }
            if (value.isNotBlank()) IconButton(enabled = enabled, onClick = { onChange("") }) {
                Icon(Icons.Outlined.Close, "$label: ${stringResource(R.string.nm_todo_unscheduled)}", Modifier.size(18.dp))
            } else Icon(Icons.Outlined.ChevronRight, null, Modifier.size(18.dp))
        }
    }
    if (isOpen && enabled) {
        val state = rememberDatePickerState(yearRange = 1..9999, initialSelectedDateMillis = parsed?.let { LocalDate.ofEpochDay(it).atStartOfDay().toInstant(ZoneOffset.UTC).toEpochMilli() })
        DatePickerDialog(onDismissRequest = { isOpen = false }, confirmButton = {
            TextButton(enabled = state.selectedDateMillis != null, onClick = {
                state.selectedDateMillis?.let { onChange(java.time.Instant.ofEpochMilli(it).atZone(ZoneOffset.UTC).toLocalDate().toString()) }
                isOpen = false
            }) { Text(stringResource(R.string.nm_todo_save)) }
        }, dismissButton = { TextButton(onClick = { isOpen = false }) { Text(stringResource(R.string.nm_todo_cancel)) } }) {
            DatePicker(state = state, title = { Text(label, Modifier.padding(start = 24.dp, top = 18.dp)) })
        }
    }
}

@Composable
private fun TodoToggle(value: Boolean, onChange: (Boolean) -> Unit, label: String, enabled: Boolean) {
    Row(Modifier.fillMaxWidth().heightIn(min = 48.dp).clickable(enabled = enabled) { onChange(!value) },
        verticalAlignment = Alignment.CenterVertically) {
        Text(label, Modifier.weight(1f))
        Switch(value, onCheckedChange = onChange, enabled = enabled)
    }
}
