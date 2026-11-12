package io.github.nanomuse.ui.todo

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.background
import androidx.compose.foundation.shape.RoundedCornerShape
import io.github.nanomuse.ui.home.MuseTones
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Add
import androidx.compose.material.icons.outlined.Search
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.openminis.app.R
import com.openminis.app.ui.theme.ChatColors
import io.github.nanomuse.account.AccountData
import io.github.nanomuse.todo.TodoStore
import io.github.nanomuse.todo.TodoTask
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.flow.onEach
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.time.LocalDate
import java.util.UUID

private const val MAX_BACKUP_BYTES = io.github.nanomuse.todo.TodoBackupLimits.MAX_BACKUP_BYTES

/** 本地待办统一入口；账号变更销毁旧编辑状态，不使用模型服务。 */
@Composable
fun TodoTab(
    header: @Composable () -> Unit = {},
    bottomInset: Dp = 0.dp,
    onOpenEditor: (String) -> Unit = {},
    onOpenFocus: (String) -> Unit = {},
) {
    val context = LocalContext.current
    val epoch by AccountData.epoch.collectAsState()
    key(epoch) {
        val store = remember(epoch) { runCatching { TodoStore.get(context) }.getOrNull() }
        if (store == null) Column { header(); Text(stringResource(R.string.nm_todo_unavailable), Modifier.padding(24.dp)) }
        else TodoPage(store, header, bottomInset, onOpenEditor, onOpenFocus)
    }
}

@Composable
private fun TodoPage(store: TodoStore, header: @Composable () -> Unit, bottomInset: Dp, onOpenEditor: (String) -> Unit, onOpenFocus: (String) -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val snackbars = remember { SnackbarHostState() }
    var reloadVersion by remember { mutableStateOf(0) }
    var hasLoadFailed by remember(store) { mutableStateOf(false) }
    var isLoading by remember(store) { mutableStateOf(true) }
    val tasks by remember(store, reloadVersion) {
        store.observeTasks().onEach { isLoading = false; hasLoadFailed = false }.catch {
            if (it is CancellationException) throw it
            isLoading = false
            hasLoadFailed = true
            emit(emptyList())
        }
    }.collectAsState(initial = emptyList())
    val categories by remember(store) { store.observeCategories() }.collectAsState(emptyList())
    val view by TodoUi.view.collectAsState()
    var query by rememberSaveable { mutableStateOf("") }
    var selectedStatus by rememberSaveable { mutableStateOf<String?>(null) }
    var quickTitle by rememberSaveable { mutableStateOf("") }
    var isAdding by remember { mutableStateOf(false) }
    var changingTaskIds by remember { mutableStateOf<Set<String>>(emptySet()) }
    var attemptedTitle by rememberSaveable { mutableStateOf<String?>(null) }
    var quickOperationId by rememberSaveable { mutableStateOf(UUID.randomUUID().toString()) }
    var editTask by remember { mutableStateOf<TodoTask?>(null) }
    var selectedId by rememberSaveable { mutableStateOf<String?>(null) }
    var isImportReview by remember { mutableStateOf(false) }
    var importContent by remember { mutableStateOf<String?>(null) }
    var isImporting by remember { mutableStateOf(false) }
    var importSummary by remember { mutableStateOf<String?>(null) }
    val selectedTask = tasks.firstOrNull { it.id == selectedId }
    // 排序和标签JSON解析只随数据变化执行，输入每个字时只匹配已缓存的字段。
    val searchable = remember(tasks) { tasks.sortedWith(compareBy<TodoTask> { it.status == "done" }
        .thenBy { it.dueDay ?: Long.MAX_VALUE }.thenByDescending { it.updatedAt }).map { task ->
            task to listOf(task.id, task.title, task.notes, task.groupName, task.tags().joinToString(" "))
        } }
    val filtered = remember(searchable, query, selectedStatus) { searchable.filter { (task, fields) ->
        (selectedStatus == null || task.status == selectedStatus) &&
            (query.isBlank() || fields.any { it.contains(query.trim(), ignoreCase = true) })
    }.map { it.first } }
    val density = LocalDensity.current
    var footerHeight by remember { mutableStateOf(84.dp) }
    val failureText = stringResource(R.string.nm_todo_save_failed)
    // 文件选择器返回时重新核对发起身份，账号切换后不把旧文件交给新账号。
    var backupOwner by rememberSaveable { mutableStateOf<String?>(null) }
    var backupEpoch by rememberSaveable { mutableStateOf<Long?>(null) }

    val exportLauncher = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument("application/json")) { uri ->
        if (uri != null && backupOwner == store.ownerKey && backupEpoch == store.ownerEpoch) scope.launch {
            try {
                val json = store.exportJson()
                check(AccountData.epoch.value == store.ownerEpoch)
                withContext(Dispatchers.IO) {
                    checkNotNull(context.contentResolver.openOutputStream(uri, "wt")).bufferedWriter().use { it.write(json) }
                }
                snackbars.showSnackbar(context.getString(R.string.nm_todo_exported))
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (_: Exception) { snackbars.showSnackbar(context.getString(R.string.nm_todo_backup_failed)) }
        }
    }
    val importLauncher = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri != null && backupOwner == store.ownerKey && backupEpoch == store.ownerEpoch) scope.launch {
            try {
                check(AccountData.epoch.value == store.ownerEpoch)
                val text = withContext(Dispatchers.IO) {
                    checkNotNull(context.contentResolver.openInputStream(uri)).use { input ->
                        val output = java.io.ByteArrayOutputStream()
                        val buffer = ByteArray(8192)
                        var count = input.read(buffer)
                        while (count >= 0) {
                            require(output.size() + count <= MAX_BACKUP_BYTES)
                            output.write(buffer, 0, count)
                            count = input.read(buffer)
                        }
                        output.toByteArray().toString(Charsets.UTF_8)
                    }
                }
                check(AccountData.epoch.value == store.ownerEpoch)
                importContent = text
                isImportReview = true
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (_: Exception) { snackbars.showSnackbar(context.getString(R.string.nm_todo_backup_failed)) }
        }
    }
    val backupAction by TodoUi.backupAction.collectAsState()
    LaunchedEffect(backupAction) {
        if (backupAction != null) {
            backupOwner = store.ownerKey
            backupEpoch = store.ownerEpoch
        }
        when (backupAction) {
            "export" -> exportLauncher.launch("nanomuse-tasks-${LocalDate.now()}.json")
            "import" -> importLauncher.launch(arrayOf("application/json", "text/plain", "application/octet-stream"))
        }
        if (backupAction != null) TodoUi.backupAction.value = null
    }

    fun addQuickTask() {
        if (isAdding || quickTitle.isBlank()) return
        val title = quickTitle
        if (attemptedTitle != null && attemptedTitle != title) quickOperationId = UUID.randomUUID().toString()
        attemptedTitle = title
        isAdding = true
        scope.launch {
            try {
                store.saveTask(TodoTask(ownerKey = store.ownerKey, title = title), quickOperationId)
                quickTitle = ""
                attemptedTitle = null
                quickOperationId = UUID.randomUUID().toString()
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (_: Exception) { snackbars.showSnackbar(failureText) }
            finally { isAdding = false }
        }
    }
    fun toggleTask(task: TodoTask) {
        if (task.id in changingTaskIds) return
        changingTaskIds = changingTaskIds + task.id
        scope.launch {
            try {
                store.changeStatus(task.id, if (task.status == "done") "todo" else "done", task.revision,
                    UUID.randomUUID().toString(), if (task.status == "done") null else LocalDate.now().toEpochDay())
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (_: Exception) { snackbars.showSnackbar(failureText) }
            finally { changingTaskIds = changingTaskIds - task.id }
        }
    }
    val pageBackground = ChatColors.background
    Box(Modifier.fillMaxSize().background(pageBackground).imePadding()) {
        Column(Modifier.fillMaxSize()) {
            header()
            // 与点子页一致，内容可滚到悬浮导航背后；末项通过contentPadding完整露出。
            LazyColumn(Modifier.weight(1f), contentPadding = PaddingValues(start = 18.dp, end = 18.dp,
                top = 14.dp, bottom = bottomInset + footerHeight + 14.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp)) {
                if (isLoading) item { LinearProgressIndicator(Modifier.fillMaxWidth()) }
                if (hasLoadFailed) item {
                    TodoPanel {
                        Text(stringResource(R.string.nm_todo_load_failed), color = MaterialTheme.colorScheme.error)
                        TextButton(onClick = { isLoading = true; hasLoadFailed = false; reloadVersion++ }) {
                            Text(stringResource(R.string.chat_longpress_retry))
                        }
                    }
                }
                if (view == TodoView.LIST) {
                    item { TodoOverview(tasks, selectedStatus) { selectedStatus = it } }
                    item {
                        OutlinedTextField(query, { query = it }, placeholder = { Text(stringResource(R.string.nm_todo_search)) },
                            leadingIcon = { Icon(Icons.Outlined.Search, null, Modifier.size(20.dp)) },
                            singleLine = true, modifier = Modifier.fillMaxWidth(), shape = RoundedCornerShape(18.dp),
                            colors = OutlinedTextFieldDefaults.colors(unfocusedContainerColor = MuseTones.surface,
                                focusedContainerColor = MuseTones.surface, unfocusedBorderColor = MuseTones.hairline))
                    }
                    item { TodoSectionTitle(selectedStatus?.let { todoStatusLabel(it) }
                        ?: stringResource(R.string.nm_todo_list), filtered.size) }
                    if (filtered.isEmpty() && !isLoading && !hasLoadFailed) item { TodoPanel { TodoEmptyState(stringResource(
                        if (tasks.isEmpty()) R.string.nm_todo_no_tasks else R.string.nm_todo_empty)) } }
                    items(filtered, key = { it.id }, contentType = { "todo_task" }) { task -> TodoTaskRow(task, onOpen = { selectedId = it.id }, onToggle = { toggleTask(task) }, isBusy = task.id in changingTaskIds) }
                } else item {
                    when (view) {
                        TodoView.CALENDAR -> TodoCalendar(tasks) { selectedId = it.id }
                        TodoView.QUADRANTS -> TodoQuadrants(tasks) { selectedId = it.id }
                        TodoView.GROUPS -> TodoGroups(tasks, categories.filter { it.kind == "group" }.map { it.name }) { selectedId = it.id }
                        TodoView.CATEGORIES -> TodoCategoryManager(store, categories)
                        TodoView.STATUS -> TodoStatuses(tasks) { selectedId = it.id }
                        TodoView.STATS -> TodoStatisticsView(tasks) { selectedId = it.id }
                        TodoView.LIST -> Unit
                    }
                }
            }
        }
        Column(Modifier.align(Alignment.BottomCenter).fillMaxWidth()
            .background(Brush.verticalGradient(listOf(pageBackground.copy(alpha = 0f), pageBackground, pageBackground)))
            .padding(bottom = bottomInset)) {
            Box(Modifier.align(Alignment.CenterHorizontally).widthIn(max = 420.dp).fillMaxWidth()
                .onSizeChanged { size -> footerHeight = with(density) { size.height.toDp() } }) {
            if (view == TodoView.LIST) TodoQuickComposer(quickTitle, { quickTitle = it.take(500) }, isAdding, ::addQuickTask,
                onDetails = { editTask = TodoTask(ownerKey = store.ownerKey, title = quickTitle) })
            else {
                FilledTonalButton(onClick = { editTask = TodoTask(ownerKey = store.ownerKey) },
                    modifier = Modifier.fillMaxWidth().padding(horizontal = 18.dp, vertical = 10.dp).heightIn(min = 48.dp),
                    shape = RoundedCornerShape(16.dp)) {
                    Icon(Icons.Outlined.Add, null, Modifier.size(18.dp))
                    Spacer(Modifier.width(8.dp))
                    Text(stringResource(R.string.nm_todo_new_task))
                }
            }
            }
        }
        SnackbarHost(snackbars, Modifier.align(Alignment.BottomCenter).padding(bottom = bottomInset + footerHeight))
    }
    editTask?.let { task -> TodoEditDialog(task, store, onDismiss = { editTask = null }, onSaved = {
        editTask = null
        if (task.id.isEmpty() && quickTitle == task.title) quickTitle = ""
    }) }
    if (selectedTask != null && editTask == null) TodoDetailDialog(selectedTask, store,
        onDismiss = { selectedId = null }, onEdit = { editTask = selectedTask }, onDeleted = { selectedId = null },
        onOpenEditor = { route -> selectedId = null; onOpenEditor(route) },
        onOpenFocus = { id -> selectedId = null; onOpenFocus(id) })
    importSummary?.let { summary -> AlertDialog(onDismissRequest = { importSummary = null },
        title = { Text(stringResource(R.string.nm_todo_import)) }, text = { Text(summary) },
        confirmButton = { TextButton(onClick = { importSummary = null }) { Text(stringResource(R.string.nm_todo_close)) } }) }
    if (isImportReview) AlertDialog(onDismissRequest = { if (!isImporting) { isImportReview = false; importContent = null } },
        title = { Text(stringResource(R.string.nm_todo_import)) },
        text = { Text(stringResource(R.string.nm_todo_import_notice)) },
        confirmButton = { TextButton(enabled = !isImporting, onClick = {
            val json = importContent ?: return@TextButton
            isImporting = true
            scope.launch {
                try {
                    val result = store.importJsonDetailed(json)
                    check(AccountData.epoch.value == store.ownerEpoch)
                    importSummary = context.getString(R.string.nm_todo_import_summary,
                        result.importedCount, result.keptLocalCount, result.missingEntryCount)
                    isImportReview = false
                    importContent = null
                } catch (cancelled: CancellationException) { throw cancelled }
                catch (_: Exception) { snackbars.showSnackbar(context.getString(R.string.nm_todo_backup_failed)) }
                finally { isImporting = false }
            }
        }) { Text(stringResource(R.string.nm_todo_import)) } },
        dismissButton = { TextButton(enabled = !isImporting, onClick = { isImportReview = false; importContent = null }) {
            Text(stringResource(R.string.nm_todo_cancel))
        } })
}
