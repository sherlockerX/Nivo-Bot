package io.github.nanomuse.ui.todo

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.runtime.remember
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import com.openminis.app.R
import io.github.nanomuse.todo.TodoTask
import io.github.nanomuse.ui.home.MuseTones

/** 列表概览只使用真实状态数量，点击摘要立即筛选，再次点击取消筛选。 */
@Composable
internal fun TodoOverview(tasks: List<TodoTask>, selectedStatus: String?, onSelect: (String?) -> Unit) {
    val states = listOf("todo", "in_progress", "done")
    val counts = remember(tasks) { tasks.groupingBy { it.status }.eachCount() }
    BoxWithConstraints {
        val stacked = maxWidth < 300.dp || LocalDensity.current.fontScale > 1.3f
        if (stacked) Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            states.forEach { status -> TodoOverviewItem(status, counts[status] ?: 0, selectedStatus == status,
                Modifier.fillMaxWidth()) { onSelect(if (selectedStatus == status) null else status) } }
        } else Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            states.forEach { status -> TodoOverviewItem(status, counts[status] ?: 0, selectedStatus == status,
                Modifier.weight(1f)) { onSelect(if (selectedStatus == status) null else status) } }
        }
    }
}

@Composable
private fun TodoOverviewItem(status: String, count: Int, selected: Boolean, modifier: Modifier, onClick: () -> Unit) {
    val color = todoStatusColor(status)
    Surface(onClick = onClick, modifier = modifier, shape = RoundedCornerShape(18.dp),
        color = if (selected) color.copy(alpha = .09f) else MuseTones.surface,
        border = BorderStroke(1.dp, if (selected) color.copy(alpha = .6f) else MuseTones.hairline.copy(alpha = .6f))) {
        Column(Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Text(count.toString(), style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.Bold, color = color)
            Text(todoStatusLabel(status), style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

/** 固定输入位于内容与原底栏之间，键盘确认与加号使用同一保存路径。 */
@Composable
internal fun TodoQuickComposer(title: String, onTitle: (String) -> Unit, isAdding: Boolean,
    onAdd: () -> Unit, onDetails: () -> Unit) {
    // 沿用点子页的通透底部背景，输入胶囊独立悬浮，避免整块白面板把导航切成两层。
    Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedTextField(title, onTitle, placeholder = { Text(stringResource(R.string.nm_todo_quick_add)) },
                    modifier = Modifier.weight(1f), enabled = !isAdding, maxLines = 3,
                    shape = RoundedCornerShape(28.dp), keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
                    keyboardActions = KeyboardActions(onDone = { if (title.isNotBlank() && !isAdding) onAdd() }),
                    trailingIcon = { IconButton(onClick = onDetails, enabled = !isAdding) {
                        Icon(Icons.Outlined.Tune, stringResource(R.string.nm_todo_add_details), Modifier.size(20.dp))
                    } },
                    colors = OutlinedTextFieldDefaults.colors(unfocusedBorderColor = Color.Transparent,
                        focusedBorderColor = MaterialTheme.colorScheme.primary.copy(alpha = .45f),
                        unfocusedContainerColor = MuseTones.bubble, focusedContainerColor = MuseTones.bubble,
                        disabledContainerColor = MuseTones.bubble, disabledBorderColor = Color.Transparent))
                FilledIconButton(onClick = onAdd, enabled = title.isNotBlank() && !isAdding,
                    modifier = Modifier.size(50.dp), shape = CircleShape) {
                    if (isAdding) CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp)
                    else Icon(Icons.Outlined.Add, stringResource(R.string.nm_todo_add))
                }
    }
}
