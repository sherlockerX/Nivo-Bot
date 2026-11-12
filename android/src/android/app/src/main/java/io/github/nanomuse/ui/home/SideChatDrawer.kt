package io.github.nanomuse.ui.home

import androidx.compose.material.icons.outlined.Checklist

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding

import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material.icons.outlined.Timer
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Archive
import androidx.compose.material.icons.outlined.Description
import androidx.compose.material.icons.outlined.Devices
import androidx.compose.material.icons.outlined.Edit
import androidx.compose.material.icons.outlined.Forum
import androidx.compose.material.icons.outlined.Home
import androidx.compose.material.icons.outlined.Lightbulb
import androidx.compose.material.icons.outlined.MoreHoriz
import androidx.compose.material.icons.outlined.Search
import androidx.compose.material.icons.outlined.Settings
import androidx.compose.material.icons.outlined.Terminal
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LocalTextStyle
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openminis.app.R
import com.openminis.app.data.db.ChatSessionEntity
import com.openminis.app.data.repository.ChatRepository
import com.openminis.app.ui.theme.ChatColors
import java.text.DateFormat
import java.util.Date

private val MIN_EXPANDED_DRAWER_HEIGHT = 400.dp

/**
 * Muse's chats drawer: the agent's name, the "main chat" row, then side chats by topic, with
 * search, settings and "new" along the bottom. The archive glyph beside the section title opens
 * the full OpenMinis session list (folders, groups, search, bulk actions) — nothing upstream is
 * lost, it just moved one tap away.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun SideChatDrawer(
    agentName: String,
    chatRepository: ChatRepository,
    providerRepository: com.openminis.app.data.repository.ProviderRepository,
    mainSessionId: String?,
    currentSessionId: String?,
    onOpenMain: () -> Unit,
    onOpenSession: (String) -> Unit,
    onNewChat: () -> Unit,
    onAllChats: () -> Unit,
    onSettings: () -> Unit,
    onSetMain: (String) -> Unit,
    onSystemFiles: (() -> Unit)? = null,
    onDevices: (() -> Unit)? = null,
    onCoding: (() -> Unit)? = null,
    onIdeas: (() -> Unit)? = null,
    onTodo: (() -> Unit)? = null,
    onFocus: (() -> Unit)? = null,
) {
    // Mosaic: subscribe once; the drawer recomposes on every frame of a drag.
    val sessions by remember(chatRepository) { chatRepository.observeSessions() }.collectAsState(initial = emptyList())
    // nanoMuse: the account's other devices, for the row under the main chat
    val hubConnected by io.github.nanomuse.hub.Hub.connected.collectAsState()
    val hubDevices by io.github.nanomuse.hub.Hub.devices.collectAsState()
    val context = androidx.compose.ui.platform.LocalContext.current
    val othersOnline = remember(hubDevices) { hubDevices.count { it.online && it.kind != "web" && it.id != io.github.nanomuse.hub.Hub.deviceId(context) } }
    // nanoMuse: computers whose runtime can show and steer coding agents (Cursor, Codex, Claude Code)
    val codingComputers = remember(hubDevices) {
        hubDevices.count { it.online && it.actions.contains("coding.sessions") && it.id != io.github.nanomuse.hub.Hub.deviceId(context) }
    }
    // nanoMuse: a chat from another device of the account is the same chat here (contract C8) — no
    // badge per chat; the turns written elsewhere carry "From Pixel 8" in the bubble instead
    var query by remember { mutableStateOf("") }
    var isSearching by remember { mutableStateOf(false) }
    var isCreatingGroup by remember { mutableStateOf(false) }
    var requestChatSelection by remember { mutableStateOf(false) } // nanoMuse: 明确多选入口，不藏在长按菜单内。
    val focusManager = LocalFocusManager.current
    val keyboard = LocalSoftwareKeyboardController.current
    val sideChats = remember(sessions, mainSessionId, query) {
        sessions
            .filter { it.id != mainSessionId }
            .filter { query.isBlank() || (it.title ?: "").contains(query, ignoreCase = true) }
            .sortedWith(compareByDescending<ChatSessionEntity> { it.pinnedAt ?: 0L }.thenByDescending { it.updatedAt })
    }

    BoxWithConstraints(
        modifier = Modifier
            .fillMaxSize()
            .background(ChatColors.background)
            .statusBarsPadding()
            .navigationBarsPadding()
            .imePadding(),
    ) {
        // 搜索和低高度窗口只保留一行工具，将入口收进菜单，为结果列表留出空间。
        val isCompact = isSearching || maxHeight < MIN_EXPANDED_DRAWER_HEIGHT * LocalDensity.current.fontScale
        Column(Modifier.fillMaxSize()) {
            // 抽屉沿用单色名称和胶囊入口，与常规高度下的外观一致。
            val nmDark = ChatColors.isDark
            val nmRowSelected = if (nmDark) Color.White.copy(alpha = 0.09f) else Color.Black.copy(alpha = 0.06f)
            val nmInk = ChatColors.primaryText
            val nmMuted = ChatColors.secondaryText
            if (!isCompact) {
                Text(
                    text = agentName,
                    fontSize = 28.sp,
                    fontWeight = FontWeight.Bold,
                    color = nmInk,
                    modifier = Modifier.padding(start = 20.dp, top = 22.dp, end = 20.dp, bottom = 18.dp),
                )

                // 主要聊天入口跟随当前会话显示选中状态。
                val mainSelected = currentSessionId == null || currentSessionId == mainSessionId
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier
                        .padding(horizontal = 12.dp)
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(12.dp))
                        .background(if (mainSelected) nmRowSelected else Color.Transparent)
                        .clickable(onClick = onOpenMain)
                        .padding(horizontal = 14.dp, vertical = 13.dp),
                ) {
                    Icon(Icons.Outlined.Home, contentDescription = null, modifier = Modifier.size(22.dp), tint = nmInk)
                    Spacer(Modifier.size(14.dp))
                    Text(
                        text = stringResource(R.string.nm_drawer_main_chat),
                        modifier = Modifier.weight(1f),
                        fontSize = 16.sp,
                        fontWeight = FontWeight.Medium,
                        color = nmInk,
                    )
                    mainSessionId?.let { SessionTaskDot(it) }
                }

                // 连接其他设备时提供入口，并保留在线状态。
                if (onDevices != null) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        modifier = Modifier
                            .padding(horizontal = 12.dp)
                            .fillMaxWidth()
                            .clip(RoundedCornerShape(12.dp))
                            .clickable(onClick = onDevices)
                            .padding(horizontal = 14.dp, vertical = 13.dp),
                    ) {
                        Icon(Icons.Outlined.Devices, contentDescription = null, modifier = Modifier.size(22.dp), tint = nmInk)
                        Spacer(Modifier.size(14.dp))
                        Text(
                            text = stringResource(R.string.nm_devices_title),
                            fontSize = 16.sp,
                            fontWeight = FontWeight.Medium,
                            color = nmInk,
                            modifier = Modifier.weight(1f),
                        )
                        Text(
                            text = when {
                                !hubConnected -> stringResource(R.string.nm_devices_off)
                                othersOnline == 0 -> stringResource(R.string.nm_hub_service_alone_short)
                                else -> pluralStringResource(R.plurals.nm_hub_service_devices, othersOnline, othersOnline)
                            },
                            fontSize = 13.sp,
                            color = nmMuted,
                        )
                    }
                }

                // 仅在可用编程设备在线时显示对应入口。
                if (onCoding != null && codingComputers > 0) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        modifier = Modifier
                            .padding(horizontal = 12.dp)
                            .fillMaxWidth()
                            .clip(RoundedCornerShape(12.dp))
                            .clickable(onClick = onCoding)
                            .padding(horizontal = 14.dp, vertical = 13.dp),
                    ) {
                        Icon(Icons.Outlined.Terminal, contentDescription = null, modifier = Modifier.size(22.dp), tint = nmInk)
                        Spacer(Modifier.size(14.dp))
                        Text(
                            text = stringResource(R.string.nm_coding_title),
                            fontSize = 16.sp,
                            fontWeight = FontWeight.Medium,
                            color = nmInk,
                            modifier = Modifier.weight(1f),
                        )
                        Text(
                            text = codingComputers.toString(),
                            fontSize = 13.sp,
                            color = nmMuted,
                        )
                    }
                }

                // 点子从底栏移至抽屉，紧凑状态下仍可从菜单访问。
                if (onIdeas != null) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        modifier = Modifier
                            .padding(horizontal = 12.dp)
                            .fillMaxWidth()
                            .clip(RoundedCornerShape(12.dp))
                            .clickable(onClick = onIdeas)
                            .padding(horizontal = 14.dp, vertical = 13.dp),
                    ) {
                        Icon(Icons.Outlined.Lightbulb, contentDescription = null, modifier = Modifier.size(22.dp), tint = nmInk)
                        Spacer(Modifier.size(14.dp))
                        Text(
                            text = stringResource(R.string.nm_tab_ideas),
                            fontSize = 16.sp,
                            fontWeight = FontWeight.Medium,
                            color = nmInk,
                        )
                    }
                }
                // 待办位于点子下方，底部导航不增加入口。
                onTodo?.let { openTodo ->
                    Row(verticalAlignment = Alignment.CenterVertically,
                        modifier = Modifier.padding(horizontal = 12.dp).fillMaxWidth()
                            .clip(RoundedCornerShape(12.dp)).clickable(onClick = openTodo)
                            .padding(horizontal = 14.dp, vertical = 13.dp)) {
                        Icon(Icons.Outlined.Checklist, null, Modifier.size(22.dp), tint = nmInk)
                        Spacer(Modifier.size(14.dp))
                        Text(stringResource(R.string.nm_todo_title), fontSize = 16.sp,
                            fontWeight = FontWeight.Medium, color = nmInk)
                    }
                }
                onFocus?.let { openFocus ->
                    Row(verticalAlignment = Alignment.CenterVertically,
                        modifier = Modifier.padding(horizontal = 12.dp).fillMaxWidth()
                            .clip(RoundedCornerShape(12.dp)).clickable(onClick = openFocus)
                            .padding(horizontal = 14.dp, vertical = 13.dp)) {
                        Icon(Icons.Outlined.Timer, null, Modifier.size(22.dp), tint = nmInk)
                        Spacer(Modifier.size(14.dp))
                        Text(stringResource(R.string.nm_focus_title), fontSize = 16.sp, fontWeight = FontWeight.Medium, color = nmInk)
                    }
                }
            }

            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.padding(start = 26.dp, end = 12.dp, top = if (isCompact) 4.dp else 14.dp),
            ) {
                if (isSearching) {
                    BasicTextField(
                        value = query, onValueChange = { query = it }, singleLine = true,
                        textStyle = LocalTextStyle.current.copy(color = nmInk, fontSize = 15.sp),
                        cursorBrush = SolidColor(nmInk), modifier = Modifier.weight(1f),
                        decorationBox = { field ->
                            Box {
                                if (query.isEmpty()) Text(stringResource(R.string.nm_drawer_search), color = nmMuted)
                                field()
                            }
                        },
                    )
                } else {
                    Text(stringResource(R.string.nm_drawer_side_chats), color = nmMuted,
                        modifier = Modifier.weight(1f), fontSize = 12.sp,
                        maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
                IconButton(onClick = { isSearching = !isSearching; if (!isSearching) query = "" }) {
                    Icon(Icons.Outlined.Search, stringResource(R.string.nm_drawer_search), tint = nmMuted)
                }
                if (isCompact) {
                    DrawerCompactMenu(
                        onOpenMain = onOpenMain,
                        onNewChat = onNewChat,
                        onAllChats = onAllChats,
                        onSettings = onSettings,
                        onCreateGroup = { isCreatingGroup = true },
                        onSelectChats = {
                            focusManager.clearFocus()
                            keyboard?.hide()
                            requestChatSelection = true
                        },
                        onSystemFiles = onSystemFiles,
                        onIdeas = onIdeas,
                        onTodo = onTodo,
                        onFocus = onFocus,
                        onDevices = onDevices,
                        onCoding = onCoding?.takeIf { codingComputers > 0 },
                    )
                } else {
                    IconButton(onClick = { isCreatingGroup = true }) {
                        Icon(Icons.Outlined.Forum, stringResource(R.string.group_new_name_hint), tint = nmMuted)
                    }
                    IconButton(onClick = onAllChats) {
                        Icon(
                            Icons.Outlined.Archive,
                            contentDescription = stringResource(R.string.nm_drawer_all_chats),
                            tint = nmMuted,
                            modifier = Modifier.size(20.dp),
                        )
                    }
                    IconButton(onClick = { requestChatSelection = true }) {
                        Icon(Icons.Outlined.Checklist, stringResource(R.string.nm_batch_select), tint = nmMuted)
                    }
                }
            }

            DrawerSessions(
                sessions = sideChats, repository = chatRepository, providers = providerRepository,
                currentSessionId = currentSessionId, query = query,
                isCreatingGroup = isCreatingGroup, onCreatedGroup = { isCreatingGroup = false },
                onOpen = onOpenSession, onSetMain = onSetMain,
                requestSelection = requestChatSelection, onSelectionHandled = { requestChatSelection = false },
                modifier = Modifier.weight(1f).fillMaxWidth(),
            )

            // 紧凑布局的菜单保留底部操作，避免键盘弹出时继续占用列表高度。
            if (!isCompact) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(start = 12.dp, end = 12.dp, bottom = 10.dp, top = 6.dp),
                ) {
                    Box(
                        modifier = Modifier
                            .size(44.dp)
                            .clip(CircleShape)
                            .background(nmRowSelected)
                            .clickable(onClick = onSettings),
                        contentAlignment = Alignment.Center,
                    ) {
                        Icon(Icons.Outlined.Settings, contentDescription = stringResource(R.string.nm_drawer_settings), tint = nmInk, modifier = Modifier.size(22.dp))
                    }
                    if (onSystemFiles != null) {
                        Spacer(Modifier.size(8.dp))
                        Box(
                            modifier = Modifier
                                .size(44.dp)
                                .clip(CircleShape)
                                .background(nmRowSelected)
                                .clickable(onClick = onSystemFiles),
                            contentAlignment = Alignment.Center,
                        ) {
                            Icon(Icons.Outlined.Description, contentDescription = stringResource(R.string.nm_sysfiles_title), tint = nmInk, modifier = Modifier.size(22.dp))
                        }
                    }
                    Spacer(Modifier.size(8.dp))
                    Spacer(Modifier.weight(1f))
                    Box(
                        modifier = Modifier
                            .size(44.dp)
                            .clip(CircleShape)
                            .background(nmRowSelected)
                            .clickable(onClick = onNewChat),
                        contentAlignment = Alignment.Center,
                    ) {
                        Icon(Icons.Outlined.Edit, contentDescription = stringResource(R.string.nm_drawer_new_chat), tint = nmInk, modifier = Modifier.size(22.dp))
                    }
                }
            }
        }
    }
}

/** 紧凑抽屉集中保留原有入口，菜单关闭后再执行对应操作。 */
@Composable
private fun DrawerCompactMenu(
    onOpenMain: () -> Unit,
    onNewChat: () -> Unit,
    onAllChats: () -> Unit,
    onSettings: () -> Unit,
    onCreateGroup: () -> Unit,
    onSelectChats: () -> Unit,
    onSystemFiles: (() -> Unit)?,
    onIdeas: (() -> Unit)?,
    onTodo: (() -> Unit)?,
    onFocus: (() -> Unit)?,
    onDevices: (() -> Unit)?,
    onCoding: (() -> Unit)?,
) {
    var isExpanded by remember { mutableStateOf(false) }
    val entries = listOfNotNull(
        Triple(R.string.nm_drawer_main_chat, Icons.Outlined.Home, onOpenMain),
        Triple(R.string.nm_drawer_new_chat, Icons.Outlined.Edit, onNewChat),
        Triple(R.string.group_new_name_hint, Icons.Outlined.Forum, onCreateGroup),
        Triple(R.string.nm_batch_select, Icons.Outlined.Checklist, onSelectChats),
        Triple(R.string.nm_drawer_all_chats, Icons.Outlined.Archive, onAllChats),
        onIdeas?.let { Triple(R.string.nm_tab_ideas, Icons.Outlined.Lightbulb, it) },
        onTodo?.let { Triple(R.string.nm_todo_title, Icons.Outlined.Checklist, it) },
        onFocus?.let { Triple(R.string.nm_focus_title, Icons.Outlined.Timer, it) },
        onDevices?.let { Triple(R.string.nm_devices_title, Icons.Outlined.Devices, it) },
        onCoding?.let { Triple(R.string.nm_coding_title, Icons.Outlined.Terminal, it) },
        onSystemFiles?.let { Triple(R.string.nm_sysfiles_title, Icons.Outlined.Description, it) },
        Triple(R.string.nm_drawer_settings, Icons.Outlined.Settings, onSettings),
    )
    Box {
        IconButton(onClick = { isExpanded = true }) {
            Icon(Icons.Outlined.MoreHoriz, stringResource(R.string.nm_more), tint = ChatColors.secondaryText)
        }
        DropdownMenu(expanded = isExpanded, onDismissRequest = { isExpanded = false }) {
            entries.forEach { (label, icon, action) ->
                DropdownMenuItem(
                    text = { Text(stringResource(label)) },
                    leadingIcon = { Icon(icon, contentDescription = null) },
                    onClick = { isExpanded = false; action() },
                )
            }
        }
    }
}

internal fun relativeDay(context: android.content.Context, ms: Long): String {
    val now = System.currentTimeMillis()
    val diff = now - ms
    return when {
        diff < 60_000L -> context.getString(R.string.nm_time_just_now)
        android.text.format.DateUtils.isToday(ms) -> DateFormat.getTimeInstance(DateFormat.SHORT).format(Date(ms))
        diff < 7L * 24 * 3600_000L -> java.text.SimpleDateFormat("EEE", java.util.Locale.getDefault()).format(Date(ms))
        else -> DateFormat.getDateInstance(DateFormat.SHORT).format(Date(ms))
    }
}
