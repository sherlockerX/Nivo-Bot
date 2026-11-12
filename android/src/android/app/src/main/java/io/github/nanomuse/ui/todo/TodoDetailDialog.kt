package io.github.nanomuse.ui.todo

import androidx.compose.foundation.clickable
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.ui.Alignment
import io.github.nanomuse.ui.home.MuseTones
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.openminis.app.R
import io.github.nanomuse.account.AccountData
import io.github.nanomuse.mosaic.MosaicStore
import io.github.nanomuse.todo.TodoStore
import io.github.nanomuse.todo.TodoTask
import io.github.nanomuse.ui.mosaic.mosaicEditRoute
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch
import java.time.LocalDate
import java.util.UUID

/** 详情仅保留跳转所需定位信息和用户文字，不读取照片内容。 */
private data class LinkedFragment(val id: String, val day: Long, val habitId: String?, val text: String)

/** 任务详情只读取用户已关联碎片的文字；回顾跳转必须由用户点击。 */
@OptIn(ExperimentalLayoutApi::class)
@Composable
internal fun TodoDetailDialog(task: TodoTask, store: TodoStore, onDismiss: () -> Unit,
    onEdit: () -> Unit, onDeleted: () -> Unit, onOpenEditor: (String) -> Unit, onOpenFocus: (String) -> Unit = {}) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var fragments by remember(task.id) { mutableStateOf<List<LinkedFragment>>(emptyList()) }
    var areLinksLoaded by remember(task.id) { mutableStateOf(false) }
    var hasLinksFailed by remember(task.id) { mutableStateOf(false) }
    var isBusy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var isDeleting by remember { mutableStateOf(false) }
    var isCompleting by remember { mutableStateOf(false) }
    var completionDate by rememberSaveable(task.id) { mutableStateOf(LocalDate.now().toString()) }
    var lastOperation by rememberSaveable(task.id) { mutableStateOf<String?>(null) }
    var operationId by rememberSaveable(task.id) { mutableStateOf(UUID.randomUUID().toString()) }
    fun operationFor(signature: String): String {
        if (lastOperation != null && lastOperation != signature) operationId = UUID.randomUUID().toString()
        lastOperation = signature
        return operationId
    }
    LaunchedEffect(task.id, task.revision) {
        hasLinksFailed = false
        areLinksLoaded = false
        try {
            val links = store.taskLinks(task.id)
            val rows = links.mapNotNull { link -> MosaicStore.get(context).entryRow(link.entryId) }
            if (store.ownerEpoch != AccountData.epoch.value) return@LaunchedEffect
            fragments = rows.filter { it.entry.deletedAt == null }.map { row ->
                LinkedFragment(row.entry.id, row.entry.day, row.entry.habitId, row.entry.text)
            }
            areLinksLoaded = true
        } catch (cancelled: CancellationException) { throw cancelled }
        catch (_: Exception) { hasLinksFailed = true }
    }
    fun changeStatus(status: String, day: Long? = null) {
        isBusy = true
        error = null
        val requestId = operationFor("status:$status:$day:${task.revision}")
        scope.launch {
            try { store.changeStatus(task.id, status, task.revision, requestId, day); isCompleting = false }
            catch (cancelled: CancellationException) { throw cancelled }
            catch (_: Exception) { error = context.getString(R.string.nm_todo_save_failed) }
            finally { isBusy = false }
        }
    }
    TodoSheet(onDismissRequest = { if (!isBusy) onDismiss() },
        title = { Text(task.title, maxLines = 3, overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis) },
        text = { Column(Modifier.fillMaxWidth(),
            verticalArrangement = Arrangement.spacedBy(12.dp)) {
            TodoPanel {
            TodoBadge(todoStatusLabel(task.status), todoStatusColor(task.status))
            if (task.notes.isNotBlank()) Text(task.notes)
            if (task.groupName.isNotBlank()) Text(stringResource(R.string.nm_todo_group_value, task.groupName))
            if (task.tags().isNotEmpty()) Text(task.tags().joinToString(" · "))
            task.scheduledDay?.let { Text(stringResource(R.string.nm_todo_scheduled_value, todoDate(it))) }
            task.dueDay?.let { Text(stringResource(R.string.nm_todo_due_value, todoDate(it))) }
            task.completedDay?.let { Text(stringResource(R.string.nm_todo_completed_value, todoDate(it))) }
            }
            TodoPanel {
            OutlinedButton(enabled = !isBusy, onClick = { onOpenFocus(task.id) }, modifier = Modifier.fillMaxWidth()) {
                Icon(Icons.Outlined.Timer, null); Spacer(Modifier.width(8.dp)); Text(stringResource(R.string.nm_focus_for_task))
            }
            io.github.nanomuse.ui.focus.FocusTaskSummary(task.id)
            TodoSectionTitle(stringResource(R.string.nm_todo_change_status))
            FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            listOf("todo", "in_progress", "done").forEach { status ->
                FilterChip(selected = status == task.status, onClick = { if (status == "done") isCompleting = true else changeStatus(status) },
                    enabled = !isBusy && status != task.status, label = { Text(todoStatusLabel(status)) },
                    leadingIcon = { Icon(if (status == "done") Icons.Outlined.CheckCircle else if (status == "in_progress") Icons.Outlined.Timelapse else Icons.Outlined.RadioButtonUnchecked, null, Modifier.size(17.dp)) })
            }
            }
            if (isCompleting) {
                TodoDateField(completionDate, { completionDate = it }, stringResource(R.string.nm_todo_completion_date), !isBusy)
                Button(onClick = {
                    val day = runCatching { parseTodoDate(completionDate) }.getOrNull()
                    if (day == null || day > LocalDate.now().toEpochDay()) error = context.getString(R.string.nm_todo_invalid_completion)
                    else changeStatus("done", day)
                }, enabled = !isBusy, modifier = Modifier.fillMaxWidth()) { Text(stringResource(R.string.nm_todo_confirm_done)) }
            }
            }
            TodoPanel {
            TodoSectionTitle(stringResource(R.string.nm_todo_linked_fragments))
            when {
                hasLinksFailed -> Text(stringResource(R.string.nm_todo_load_failed))
                !areLinksLoaded -> CircularProgressIndicator(Modifier.size(24.dp))
                fragments.isEmpty() -> Text(stringResource(R.string.nm_todo_no_fragments))
                else -> fragments.forEach { fragment ->
                    Surface(color = MaterialTheme.colorScheme.surfaceContainerHigh, modifier = Modifier.fillMaxWidth()
                        .clickable { onOpenEditor(mosaicEditRoute(fragment.day, fragment.habitId, fragment.id)) }) {
                        Column(Modifier.padding(12.dp)) {
                            Text(todoDate(fragment.day), style = MaterialTheme.typography.labelLarge)
                            Text(fragment.text.ifBlank { context.getString(R.string.nm_todo_fragment_without_text) }.take(240))
                        }
                    }
                }
            }
            }
            error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
            TextButton(onClick = { isDeleting = true }, enabled = !isBusy) {
                Text(stringResource(R.string.nm_todo_delete), color = MaterialTheme.colorScheme.error)
            }
        } }, confirmButton = { Button(enabled = !isBusy, onClick = onEdit, shape = RoundedCornerShape(14.dp), contentPadding = PaddingValues(horizontal = 28.dp, vertical = 12.dp)) { Text(stringResource(R.string.nm_todo_edit)) } },
        dismissButton = { TextButton(enabled = !isBusy, onClick = onDismiss) { Text(stringResource(R.string.nm_todo_close)) } })
    if (isDeleting) AlertDialog(onDismissRequest = { if (!isBusy) isDeleting = false },
        title = { Text(stringResource(R.string.nm_todo_delete)) }, text = { Text(stringResource(R.string.nm_todo_delete_notice)) },
        confirmButton = { TextButton(enabled = !isBusy, onClick = {
            isBusy = true
            val requestId = operationFor("delete:${task.revision}")
            scope.launch {
                try { store.deleteTask(task.id, task.revision, requestId); onDeleted() }
                catch (cancelled: CancellationException) { throw cancelled }
                catch (_: Exception) { error = context.getString(R.string.nm_todo_save_failed); isDeleting = false }
                finally { isBusy = false }
            }
        }) { Text(stringResource(R.string.nm_todo_delete)) } },
        dismissButton = { TextButton(enabled = !isBusy, onClick = { isDeleting = false }) { Text(stringResource(R.string.nm_todo_cancel)) } })
}
