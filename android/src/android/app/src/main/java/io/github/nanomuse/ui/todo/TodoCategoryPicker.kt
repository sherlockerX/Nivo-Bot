package io.github.nanomuse.ui.todo

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.automirrored.outlined.Label
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.unit.dp
import com.openminis.app.R
import io.github.nanomuse.todo.TodoCategory
import io.github.nanomuse.todo.TodoCategoryRules
import io.github.nanomuse.todo.TodoStore
import io.github.nanomuse.ui.home.MuseTones
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.launch

/** 分组单选、标签多选共用目录入口，点击后在独立面板搜索或明确创建。 */
@OptIn(ExperimentalLayoutApi::class)
@Composable
internal fun TodoCategoryFields(group: String, tags: List<String>, enabled: Boolean, onOpen: (String) -> Unit) {
    listOf(TodoCategoryRules.GROUP, TodoCategoryRules.TAG).forEach { kind ->
        val label = stringResource(if (kind == TodoCategoryRules.GROUP) R.string.nm_todo_group else R.string.nm_todo_tags)
        Surface(onClick = { onOpen(kind) }, enabled = enabled, shape = RoundedCornerShape(14.dp), color = MuseTones.fill) {
            Row(Modifier.fillMaxWidth().padding(14.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Icon(if (kind == TodoCategoryRules.GROUP) Icons.Outlined.FolderOpen else Icons.AutoMirrored.Outlined.Label, null)
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(5.dp)) {
                    Text(label, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    Text(if (kind == TodoCategoryRules.GROUP) group.ifBlank { stringResource(R.string.nm_todo_choose_category) }
                        else tags.joinToString(" · ").ifBlank { stringResource(R.string.nm_todo_choose_category) }, style = MaterialTheme.typography.bodyMedium)
                }
                Icon(Icons.Outlined.ChevronRight, null)
            }
        }
    }
}

/** 目录独立保存；任务编辑取消后，明确创建的分类仍然可复用。 */
@Composable
internal fun TodoCategoryPicker(store: TodoStore, kind: String, selected: List<String>,
    onSelection: (List<String>) -> Unit, onDismiss: () -> Unit, isManager: Boolean = false) {
    var error by remember { mutableStateOf(false) }
    val rows by remember(store) { store.observeCategories().catch {
        if (it is CancellationException) throw it
        error = true
    } }.collectAsState(emptyList())
    var query by rememberSaveable(kind) { mutableStateOf("") }
    var isSaving by remember { mutableStateOf(false) }
    var deleting by remember { mutableStateOf<TodoCategory?>(null) }
    val scope = rememberCoroutineScope()
    val names = remember(rows, kind, selected) { (rows.filter { it.kind == kind }.map { it.name } + selected).distinct().sorted() }
    val filtered = remember(names, query) { names.filter { it.contains(query.trim(), ignoreCase = true) } }
    val clean = query.trim()
    val canCreate = remember(kind, clean, names, selected.size, isManager) { runCatching { TodoCategoryRules.name(kind, clean) }.isSuccess && clean !in names && (isManager || kind == TodoCategoryRules.GROUP || selected.size < 50) }
    TodoSheet(onDismissRequest = { if (!isSaving) onDismiss() }, title = {
        Text(stringResource(if (kind == TodoCategoryRules.GROUP) R.string.nm_todo_groups else R.string.nm_todo_tags))
    }, text = {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text(stringResource(R.string.nm_todo_category_hint), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            OutlinedTextField(query, { query = it }, singleLine = true, enabled = !isSaving,
                modifier = Modifier.fillMaxWidth(), shape = RoundedCornerShape(16.dp),
                label = { Text(stringResource(R.string.nm_todo_category_search)) }, leadingIcon = { Icon(Icons.Outlined.Search, null) })
            if (canCreate) FilledTonalButton(enabled = !isSaving, onClick = {
                isSaving = true; error = false
                scope.launch {
                    try {
                        val name = store.createCategory(kind, clean)
                        if (!isManager) onSelection(if (kind == TodoCategoryRules.GROUP) listOf(name) else (selected + name).distinct())
                        query = ""
                    } catch (cancelled: CancellationException) { throw cancelled }
                    catch (_: Exception) { error = true }
                    finally { isSaving = false }
                }
            }, modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp)) {
                Icon(Icons.Outlined.Add, null); Spacer(Modifier.width(8.dp))
                Text(stringResource(R.string.nm_todo_category_create, clean))
            }
            if (isSaving) LinearProgressIndicator(Modifier.fillMaxWidth())
            if (error) Text(stringResource(R.string.nm_todo_save_failed), color = MaterialTheme.colorScheme.error)
            if (filtered.isEmpty()) Text(stringResource(R.string.nm_todo_category_empty), style = MaterialTheme.typography.bodyMedium)
            LazyColumn(Modifier.fillMaxWidth().heightIn(max = 320.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                if (kind == TodoCategoryRules.GROUP && !isManager) item(key = "none") {
                    CategoryOption(stringResource(R.string.nm_todo_ungrouped), selected.isEmpty(), !isSaving) { onSelection(emptyList()) }
                }
                items(filtered, key = { "name:$it" }) { name ->
                    if (isManager) Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                        Text(name, Modifier.weight(1f).padding(12.dp))
                        IconButton(enabled = !isSaving, onClick = { deleting = rows.firstOrNull { it.kind == kind && it.name == name } }) {
                            Icon(Icons.Outlined.DeleteOutline, stringResource(R.string.nm_category_delete), tint = MaterialTheme.colorScheme.error)
                        }
                    } else CategoryOption(name, name in selected, !isSaving && (kind == TodoCategoryRules.GROUP || name in selected || selected.size < 50)) {
                        onSelection(if (kind == TodoCategoryRules.GROUP) listOf(name)
                            else if (name in selected) selected - name else selected + name)
                    }
                }
            }
        }
    }, confirmButton = { TextButton(enabled = !isSaving, onClick = onDismiss) { Text(stringResource(R.string.nm_todo_close)) } }, dismissButton = {})
    deleting?.let { category ->
        AlertDialog(onDismissRequest = { if (!isSaving) deleting = null },
            title = { Text(stringResource(R.string.nm_category_delete)) },
            text = { Text(stringResource(if (kind == TodoCategoryRules.GROUP) R.string.nm_category_delete_group_hint else R.string.nm_category_delete_tag_hint, category.name)) },
            confirmButton = { TextButton(enabled = !isSaving, onClick = {
                isSaving = true
                scope.launch {
                    try { store.deleteCategory(kind, category.name, category.createdAt); deleting = null }
                    catch (cancelled: CancellationException) { throw cancelled }
                    catch (_: Exception) { error = true; deleting = null }
                    finally { isSaving = false }
                }
            }) { Text(stringResource(R.string.nm_category_delete)) } },
            dismissButton = { TextButton(enabled = !isSaving, onClick = { deleting = null }) { Text(stringResource(R.string.nm_todo_close)) } })
    }
}

/** 整行48dp点击区域与勾选语义同时表达选择，不仅依赖颜色。 */
@Composable
private fun CategoryOption(name: String, selected: Boolean, enabled: Boolean, onClick: () -> Unit) {
    Surface(onClick = onClick, enabled = enabled, modifier = Modifier.semantics { this.selected = selected }, shape = RoundedCornerShape(14.dp),
        color = if (selected) MaterialTheme.colorScheme.primary.copy(alpha = .09f) else MuseTones.fill) {
        Row(Modifier.fillMaxWidth().heightIn(min = 48.dp).padding(horizontal = 14.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Text(name, Modifier.weight(1f))
            if (selected) Icon(Icons.Outlined.Check, stringResource(R.string.nm_todo_selected), tint = MaterialTheme.colorScheme.primary)
        }
    }
}

/** 右上模块提供独立分类管理，无需先创建一条任务。 */
@Composable
internal fun TodoCategoryManager(store: TodoStore, categories: List<TodoCategory>) {
    var kind by rememberSaveable { mutableStateOf<String?>(null) }
    Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
        Text(stringResource(R.string.nm_todo_category_hint), style = MaterialTheme.typography.bodyMedium)
        listOf(TodoCategoryRules.GROUP, TodoCategoryRules.TAG).forEach { item ->
            TodoPanel {
                TodoSectionTitle(stringResource(if (item == TodoCategoryRules.GROUP) R.string.nm_todo_groups else R.string.nm_todo_tags), categories.count { it.kind == item })
                Text(categories.filter { it.kind == item }.take(8).joinToString(" · ") { it.name }
                    .ifEmpty { stringResource(R.string.nm_todo_category_empty) }, style = MaterialTheme.typography.bodyMedium)
                OutlinedButton(onClick = { kind = item }, modifier = Modifier.heightIn(min = 48.dp)) {
                    Icon(Icons.Outlined.Add, null); Spacer(Modifier.width(8.dp)); Text(stringResource(R.string.nm_todo_category_manage))
                }
            }
        }
    }
    kind?.let { TodoCategoryPicker(store, it, emptyList(), {}, { kind = null }, isManager = true) }
}
