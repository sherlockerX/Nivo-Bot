package io.github.nanomuse.ui.focus

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.openminis.app.R
import io.github.nanomuse.account.AccountData
import io.github.nanomuse.focus.FocusStore
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.catch

/** 任务详情直接回顾投入时长，保持计时和完成状态分离。 */
@Composable
fun FocusTaskSummary(taskId:String) {
    val context=LocalContext.current
    val epoch by AccountData.epoch.collectAsState()
    val store=remember(epoch) { runCatching { FocusStore.get(context) }.getOrNull() } ?: return
    val records by remember(store) { store.observe().catch { if(it is CancellationException) throw it;emit(emptyList()) } }.collectAsState(emptyList())
    val finished=records.filter { it.taskId==taskId && it.status=="finished" && it.mode!="break" }
    if(finished.isNotEmpty()) Column(verticalArrangement=Arrangement.spacedBy(6.dp)) {
        Text(stringResource(R.string.nm_focus_title)+" · "+formatFocusDuration(finished.sumOf { it.elapsedMs }),style=MaterialTheme.typography.titleMedium)
        finished.take(3).forEach { Text(formatFocusRange(it.startedAt,it.endedAt ?: it.startedAt)+" · "+formatFocusDuration(it.elapsedMs),style=MaterialTheme.typography.bodySmall) }
    }
}
