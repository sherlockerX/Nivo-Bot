package io.github.nanomuse.ui.focus

import androidx.compose.runtime.*
import androidx.compose.material3.*
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import com.openminis.app.R
import io.github.nanomuse.account.AccountData
import io.github.nanomuse.focus.FocusStore
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.CancellationException

/** 日记列表直接显示关联时段，不必先打开编辑器才能知道记录了什么。 */
@Composable
fun FocusRecordSummary(entryId:String) {
    val context=LocalContext.current
    val epoch by AccountData.epoch.collectAsState()
    val store=remember(epoch) { runCatching { FocusStore.get(context) }.getOrNull() } ?: return
    val links by remember(store,entryId) { store.observeEntryLinks(entryId).catch { if(it is CancellationException) throw it;emit(emptyList()) } }.collectAsState(emptyList())
    if(links.isNotEmpty()) Text(stringResource(R.string.nm_focus_title)+" · "+links.joinToString(" / ") { it.title+" "+formatFocusDuration(it.durationMs) },style=MaterialTheme.typography.bodySmall,color=MaterialTheme.colorScheme.onSurfaceVariant)
}
