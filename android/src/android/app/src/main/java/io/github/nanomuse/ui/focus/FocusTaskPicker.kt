package io.github.nanomuse.ui.focus

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Add
import androidx.compose.material.icons.outlined.Search
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.openminis.app.R
import io.github.nanomuse.todo.TodoStore
import io.github.nanomuse.todo.TodoTask
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.launch
import java.util.UUID

/**
 * 专注页的待办选择：同一个输入框搜索已有待办，没有合适的就地新建并直接选中。
 * 新建走待办的同一个存储入口，待办列表立刻出现这一项，分组也是待办页的分组。
 */
@OptIn(ExperimentalLayoutApi::class)
@Composable
internal fun FocusTaskPicker(tasks: List<TodoTask>, store: TodoStore, onPick: (String) -> Unit, onDismiss: () -> Unit) {
    val scope = rememberCoroutineScope()
    val categories by remember(store) { store.observeCategories().catch { if (it is CancellationException) throw it; emit(emptyList()) } }
        .collectAsState(emptyList())
    var query by rememberSaveable { mutableStateOf("") }
    var group by rememberSaveable { mutableStateOf("") }
    var isSaving by remember { mutableStateOf(false) }
    var hasFailed by remember { mutableStateOf(false) }
    // 同一次输入的重试沿用操作ID，网络或磁盘抖动后再点不会建出两条。
    var operationId by remember { mutableStateOf(UUID.randomUUID().toString()) }
    var attempted by remember { mutableStateOf<Pair<String, String>?>(null) }
    val title = query.trim()
    val open = remember(tasks) { tasks.filter { it.status != "done" } }
    val matching = remember(open, title) { open.filter { title.isEmpty() || it.title.contains(title, ignoreCase = true) } }
    val groups = remember(categories, open) {
        (categories.filter { it.kind == "group" }.map { it.name } + open.map { it.groupName })
            .map(String::trim).filter(String::isNotEmpty).distinct().sorted()
    }
    val canCreate = title.isNotEmpty() && open.none { it.title.trim().equals(title, ignoreCase = true) }

    fun create() {
        if (isSaving || !canCreate) return
        val request = title to group
        if (attempted != null && attempted != request) operationId = UUID.randomUUID().toString()
        attempted = request
        isSaving = true
        hasFailed = false
        scope.launch {
            try {
                val saved = store.saveTask(TodoTask(ownerKey = store.ownerKey, title = title, groupName = group), operationId)
                onPick(saved.id)
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (_: Exception) { hasFailed = true }
            finally { isSaving = false }
        }
    }

    AlertDialog(onDismissRequest = { if (!isSaving) onDismiss() },
        title = { Text(stringResource(R.string.nm_focus_choose_task)) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                OutlinedTextField(query, { query = it.take(500); hasFailed = false }, modifier = Modifier.fillMaxWidth(),
                    placeholder = { Text(stringResource(R.string.nm_focus_search_or_new)) },
                    leadingIcon = { Icon(Icons.Outlined.Search, null) }, singleLine = true, enabled = !isSaving)
                if (canCreate) {
                    Text(stringResource(R.string.nm_focus_new_task_group), style = MaterialTheme.typography.labelMedium)
                    FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        FilterChip(selected = group.isEmpty(), onClick = { group = "" },
                            label = { Text(stringResource(R.string.nm_todo_ungrouped)) })
                        groups.forEach { name ->
                            FilterChip(selected = group == name, onClick = { group = name }, label = { Text(name) })
                        }
                    }
                    Button(onClick = ::create, enabled = !isSaving, modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp)) {
                        if (isSaving) CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp)
                        else Icon(Icons.Outlined.Add, null, Modifier.size(18.dp))
                        Spacer(Modifier.width(8.dp))
                        Text(stringResource(R.string.nm_focus_add_task, title), maxLines = 1, overflow = TextOverflow.Ellipsis)
                    }
                }
                if (hasFailed) Text(stringResource(R.string.nm_focus_add_failed), color = MaterialTheme.colorScheme.error)
                if (open.isEmpty() && !canCreate) Text(stringResource(R.string.nm_focus_no_open_tasks),
                    style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                LazyColumn(Modifier.fillMaxWidth().heightIn(max = 320.dp)) {
                    items(matching, key = { it.id }) { task ->
                        TextButton(onClick = { onPick(task.id) }, enabled = !isSaving, modifier = Modifier.fillMaxWidth()) {
                            Column(Modifier.fillMaxWidth()) {
                                Text(task.title, fontWeight = FontWeight.Medium, maxLines = 2, overflow = TextOverflow.Ellipsis)
                                Text(task.groupName.ifBlank { stringResource(R.string.nm_todo_ungrouped) },
                                    style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                            }
                        }
                    }
                }
            }
        },
        confirmButton = { TextButton(onClick = onDismiss, enabled = !isSaving) { Text(stringResource(R.string.nm_todo_close)) } })
}
