package io.github.nanomuse.ui.home

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.Alignment
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.openminis.app.R
import com.openminis.app.data.db.ChatSessionEntity
import com.openminis.app.data.repository.ChatRepository
import com.openminis.app.data.repository.ProviderRepository
import com.openminis.app.ui.sessions.*
import kotlinx.coroutines.launch

/** 侧栏复用归档菜单和分组操作，列表只绘制可见行。 */
@Composable
internal fun DrawerSessions(
    sessions: List<ChatSessionEntity>,
    repository: ChatRepository,
    providers: ProviderRepository,
    currentSessionId: String?,
    query: String,
    isCreatingGroup: Boolean,
    onCreatedGroup: () -> Unit,
    onOpen: (String) -> Unit,
    onSetMain: (String) -> Unit,
    modifier: Modifier = Modifier,
    requestSelection: Boolean = false, onSelectionHandled: () -> Unit = {},
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val vm: SessionListViewModel = androidx.lifecycle.viewmodel.compose.viewModel(
        key = "nanomuse-drawer-sessions",
        factory = SessionListViewModel.factory(repository, providers, context.applicationContext),
    )
    val folders by vm.folders.collectAsState()
    val counts by vm.folderMemberCounts.collectAsState()
    val request by vm.groupPickerRequest.collectAsState()
    val isSelecting by vm.isSelecting.collectAsState()
    val selected by vm.selectedIds.collectAsState()
    val regenerating by vm.regeneratingIds.collectAsState()
    val isDeleting by vm.isDeletingSessions.collectAsState()
    var groupError by remember { mutableStateOf<String?>(null) }
    var editing by remember { mutableStateOf<ChatSessionEntity?>(null) }
    var deleting by remember { mutableStateOf<Set<String>>(emptySet()) }
    var collapsed by rememberSaveable { mutableStateOf(listOf(io.github.nanomuse.chat.GroupNamePolicy.SYSTEM_ID)) }
    LaunchedEffect(requestSelection) {
        if (requestSelection) { vm.beginSelection(); onSelectionHandled() }
    }
    val candidateIds = remember(sessions) { sessions.map { it.id }.toSet() }
    LaunchedEffect(candidateIds) { vm.restrictSelection(candidateIds) }
    val groups = remember(sessions, folders) {
        val folderIds = folders.map { it.id }.toSet()
        sessions.groupBy { it.folderId?.takeIf(folderIds::contains) }
    }
    Column(modifier) {
        if (isSelecting) {
            Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp), verticalAlignment = Alignment.CenterVertically) {
                Text(stringResource(R.string.nm_batch_selected, selected.size), modifier = Modifier.weight(1f), style = MaterialTheme.typography.labelLarge)
                TextButton(onClick = { vm.selectAll(candidateIds) }, enabled = !isDeleting && candidateIds.isNotEmpty()) {
                    Text(stringResource(if (candidateIds.isNotEmpty() && selected.containsAll(candidateIds)) R.string.sessionlist_deselect_all else R.string.nm_batch_scope_all))
                }
            }
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceEvenly) {
                TextButton(onClick = vm::clearSelection) { Text(stringResource(R.string.cancel)) }
                TextButton(onClick = vm::requestGroupPickerForSelection, enabled = selected.isNotEmpty()) {
                    Text(stringResource(R.string.group_move_to))
                }
                TextButton(onClick = { deleting = selected.toSet() }, enabled = selected.isNotEmpty() && !isDeleting) {
                    Text(stringResource(R.string.delete))
                }
            }
        }
        LazyColumn(Modifier.weight(1f).fillMaxWidth(), contentPadding = PaddingValues(vertical = 4.dp)) {
            val ordered = folders.sortedWith(compareByDescending<com.openminis.app.data.db.FolderEntity> { it.pinnedAt ?: 0L }.thenBy { it.name })
            ordered.forEach { folder ->
                val members = groups[folder.id].orEmpty()
                if (folder.id == io.github.nanomuse.chat.GroupNamePolicy.SYSTEM_ID && members.isEmpty()) return@forEach
                if (query.isBlank() || members.isNotEmpty()) {
                    item("folder:${folder.id}") {
                        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                        Text(
                            text = "${if (folder.id in collapsed) "▸" else "▾"} ${folder.name} (${members.size})",
                            modifier = Modifier.weight(1f).clickable {
                                collapsed = if (folder.id in collapsed) collapsed - folder.id else collapsed + folder.id
                            }.padding(horizontal = 20.dp, vertical = 10.dp),
                            style = MaterialTheme.typography.labelLarge,
                        )
                        if (isSelecting) Checkbox(checked = members.isNotEmpty() && selected.containsAll(members.map { it.id }),
                            enabled = !isDeleting && members.isNotEmpty(), onCheckedChange = { vm.selectAll(members.map { it.id }.toSet()) })
                        }
                    }
                }
                if (folder.id !in collapsed || query.isNotBlank()) {
                    items(members, key = { it.id }) { session ->
                        DrawerSessionItem(session, vm, isSelecting, selected, regenerating, query,
                            currentSessionId, true, onOpen, onSetMain,
                            { editing = it }, { deleting = setOf(it) }, repository)
                    }
                }
            }
            val ungrouped = groups[null].orEmpty()
            item("ungrouped:header") {
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Text("${if ("__ungrouped__" in collapsed) "▸" else "▾"} ${stringResource(R.string.nm_ungrouped)} (${ungrouped.size})",
                    style = MaterialTheme.typography.labelLarge,
                    modifier = Modifier.weight(1f).clickable {
                        collapsed = if ("__ungrouped__" in collapsed) collapsed - "__ungrouped__" else collapsed + "__ungrouped__"
                    }.padding(horizontal = 20.dp, vertical = 10.dp))
                if (isSelecting) Checkbox(checked = ungrouped.isNotEmpty() && selected.containsAll(ungrouped.map { it.id }),
                    enabled = !isDeleting && ungrouped.isNotEmpty(), onCheckedChange = { vm.selectAll(ungrouped.map { it.id }.toSet()) })
                }
            }
            if ("__ungrouped__" !in collapsed || query.isNotBlank()) items(ungrouped, key = { it.id }) { session ->
                DrawerSessionItem(session, vm, isSelecting, selected, regenerating, query,
                    currentSessionId, false, onOpen, onSetMain,
                    { editing = it }, { deleting = setOf(it) }, repository)
            }
        }
    }
    request?.let { pending ->
        GroupPickerSheet(folders = folders, memberCounts = counts,
            sessionCount = pending.sessionIds.size, anyFiled = pending.anyFiled,
            onChoose = vm::applyGroupChoice, onDismiss = vm::dismissGroupPicker)
    }
    if (isCreatingGroup) DrawerNameDialog(
        title = stringResource(R.string.group_new_name_hint), initial = "", onDismiss = onCreatedGroup,
        errorText = groupError, onSave = { name -> scope.launch {
            try { repository.createFolder(name); groupError = null; onCreatedGroup() }
            catch (cancelled: kotlinx.coroutines.CancellationException) { throw cancelled }
            catch (failure: Exception) { groupError = io.github.nanomuse.ui.home.groupError(context, failure) }
        } },
    )
    editing?.let { session ->
        DrawerNameDialog(title = stringResource(R.string.sessionlist_edit_title_category),
            initial = session.title.orEmpty(), initialCategory = session.category.orEmpty(),
            onDismiss = { editing = null }, onSaveCategory = { name, category ->
                vm.updateTitleAndCategory(session.id, name, category.ifBlank { null }); editing = null
            })
    }
    if (deleting.isNotEmpty()) AlertDialog(
        onDismissRequest = { if (!isDeleting) deleting = emptySet() },
        title = { Text(stringResource(R.string.delete)) },
        text = { Text(stringResource(R.string.nm_drawer_delete_count, deleting.size)) },
        confirmButton = { TextButton(enabled = !isDeleting, onClick = {
            vm.deleteSessions(deleting.toSet()) { deleting = emptySet() }
        }) { Text(stringResource(R.string.delete)) } },
        dismissButton = { TextButton(enabled = !isDeleting, onClick = { deleting = emptySet() }) { Text(stringResource(R.string.cancel)) } },
    )
}

/** 将归档对话行的回调绑定到侧栏管理状态。 */
@Composable
private fun DrawerSessionItem(
    session: ChatSessionEntity, vm: SessionListViewModel, isSelecting: Boolean,
    selected: Set<String>, regenerating: Set<String>, query: String,
    currentId: String?, isFiled: Boolean, onOpen: (String) -> Unit, onSetMain: (String) -> Unit,
    onEdit: (ChatSessionEntity) -> Unit, onDelete: (String) -> Unit, repository: ChatRepository,
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    SessionItemContent(
        session = session, isSelecting = isSelecting, selectedIds = selected,
        onSessionClick = onOpen, onToggleSelect = vm::toggleSelect, onEnterSelect = vm::enterSelection,
        onPinToggle = vm::togglePin, onEditRequest = onEdit,
        onExportRequest = { record, format -> exportSession(context, record, repository, scope, format) },
        onRegenerateTitle = vm::regenerateTitle, onDuplicate = vm::duplicateSession,
        onDeleteRequest = onDelete, onMoveToGroup = vm::requestGroupPicker,
        isFiled = isFiled, isRegenerating = session.id in regenerating, searchQuery = query,
        rowBackground = if (session.id == currentId) MaterialTheme.colorScheme.secondaryContainer else null,
        onSetMain = { onSetMain(session.id) },
    )
}

/** 使用独立对话框编辑名称，避免触及聊天输入框的焦点和草稿。 */
@Composable
private fun DrawerNameDialog(
    title: String, initial: String, onDismiss: () -> Unit,
    initialCategory: String? = null, onSave: ((String) -> Unit)? = null,
    onSaveCategory: ((String, String) -> Unit)? = null,
    errorText: String? = null,
) {
    var name by rememberSaveable { mutableStateOf(initial) }
    var category by rememberSaveable { mutableStateOf(initialCategory.orEmpty()) }
    AlertDialog(onDismissRequest = onDismiss, title = { Text(title) }, text = {
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            OutlinedTextField(name, { name = it }, singleLine = true)
            errorText?.let { Text(it, color = MaterialTheme.colorScheme.error) }
            if (initialCategory != null) OutlinedTextField(category, { category = it }, singleLine = true)
        }
    }, confirmButton = {
        TextButton(enabled = name.isNotBlank(), onClick = {
            onSave?.invoke(name); onSaveCategory?.invoke(name.trim(), category.trim())
        }) { Text(stringResource(R.string.save)) }
    }, dismissButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.cancel)) } })
}
