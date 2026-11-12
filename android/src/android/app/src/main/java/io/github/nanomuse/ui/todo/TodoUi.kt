package io.github.nanomuse.ui.todo

import androidx.annotation.StringRes
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.automirrored.outlined.Label
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.openminis.app.R
import io.github.nanomuse.ui.home.MuseTones
import kotlinx.coroutines.flow.MutableStateFlow

/** 单一待办入口，模块切换不追加全局导航。 */
object TodoUi {
    val view = MutableStateFlow(TodoView.LIST)
    val backupAction = MutableStateFlow<String?>(null)
    /** 子视图返回到默认任务列表。 */
    fun back() { view.value = TodoView.LIST }
}

/** 同一数据集的六个视图，图标仅辅助文字。 */
enum class TodoView(@StringRes val label: Int) {
    LIST(R.string.nm_todo_list), CALENDAR(R.string.nm_todo_calendar),
    QUADRANTS(R.string.nm_todo_quadrants), GROUPS(R.string.nm_todo_groups),
    CATEGORIES(R.string.nm_todo_categories), STATUS(R.string.nm_todo_status), STATS(R.string.nm_todo_statistics),
}

/** 模块图标由稳定枚举映射，菜单与页面共用。 */
internal fun todoViewIcon(view: TodoView): ImageVector = when (view) {
    TodoView.LIST -> Icons.Outlined.Checklist
    TodoView.CALENDAR -> Icons.Outlined.CalendarMonth
    TodoView.QUADRANTS -> Icons.Outlined.GridView
    TodoView.GROUPS -> Icons.Outlined.FolderOpen
    TodoView.CATEGORIES -> Icons.AutoMirrored.Outlined.Label
    TodoView.STATUS -> Icons.Outlined.DonutLarge
    TodoView.STATS -> Icons.Outlined.PieChartOutline
}

/** 顶栏强调当前模块，右上菜单保留全部模块和备份入口。 */
@Composable
fun TodoHeader(onOpenDrawer: () -> Unit) {
    val view by TodoUi.view.collectAsState()
    var isMenuOpen by remember { mutableStateOf(false) }
    Row(Modifier.fillMaxWidth().background(com.openminis.app.ui.theme.ChatColors.background).statusBarsPadding()
        .padding(horizontal = 12.dp, vertical = 10.dp), verticalAlignment = Alignment.CenterVertically) {
        IconButton(onClick = if (view == TodoView.LIST) onOpenDrawer else TodoUi::back) {
            Icon(if (view == TodoView.LIST) Icons.Outlined.Menu else Icons.AutoMirrored.Outlined.ArrowBack,
                stringResource(if (view == TodoView.LIST) R.string.nm_open_drawer else R.string.nm_todo_back_list))
        }
        Column(Modifier.weight(1f).padding(horizontal = 10.dp)) {
            if (view != TodoView.LIST) Text(stringResource(R.string.nm_todo_title),
                style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Text(stringResource(if (view == TodoView.LIST) R.string.nm_todo_title else view.label),
                style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.Bold)
        }
        Box {
            FilledTonalIconButton(onClick = { isMenuOpen = true }, shape = RoundedCornerShape(14.dp),
                colors = IconButtonDefaults.filledTonalIconButtonColors(containerColor = MuseTones.surface)) {
                Icon(Icons.Outlined.DashboardCustomize, stringResource(R.string.nm_todo_modules), Modifier.size(22.dp))
            }
            DropdownMenu(expanded = isMenuOpen, onDismissRequest = { isMenuOpen = false },
                shape = RoundedCornerShape(22.dp), containerColor = MuseTones.surface) {
                TodoView.entries.forEach { item ->
                    DropdownMenuItem(text = { Text(stringResource(item.label), fontWeight = if (item == view) FontWeight.SemiBold else FontWeight.Normal) },
                        leadingIcon = { Icon(todoViewIcon(item), null, Modifier.size(20.dp)) },
                        trailingIcon = { if (item == view) Icon(Icons.Outlined.Check, null, Modifier.size(18.dp), tint = MaterialTheme.colorScheme.primary) },
                        onClick = { isMenuOpen = false; TodoUi.view.value = item })
                }
                HorizontalDivider(Modifier.padding(horizontal = 12.dp, vertical = 6.dp), color = MuseTones.hairline)
                DropdownMenuItem(text = { Text(stringResource(R.string.nm_todo_export)) }, leadingIcon = { Icon(Icons.Outlined.FileUpload, null) },
                    onClick = { isMenuOpen = false; TodoUi.backupAction.value = "export" })
                DropdownMenuItem(text = { Text(stringResource(R.string.nm_todo_import)) }, leadingIcon = { Icon(Icons.Outlined.FileDownload, null) },
                    onClick = { isMenuOpen = false; TodoUi.backupAction.value = "import" })
            }
        }
    }
}
