package com.openminis.app.ui.scheduled

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Error
import androidx.compose.material.icons.outlined.History
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openminis.app.R
import com.openminis.app.scheduled.ScheduledRun
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * [T-android-scheduled-tasks-run-records] Execution log for one scheduled
 * task. Lists each recorded run newest-first; a run that produced a chat
 * (non-null sessionId) is tappable → opens that chat. Backed by the live
 * tasks flow so new runs appear without re-entering the screen.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ScheduledTaskRunsScreen(
    taskId: String,
    onBack: () -> Unit,
    onOpenSession: (sessionId: String) -> Unit,
) {
    val context = LocalContext.current
    val vm: ScheduledTasksViewModel = androidx.lifecycle.viewmodel.compose.viewModel(
        factory = ScheduledTasksViewModel.factory(context),
    )
    val tasks by vm.tasks.collectAsState()
    val task = tasks.firstOrNull { it.id == taskId }
    val runs = task?.runHistory ?: emptyList()
    // nanoMuse: 运行日志里的结果全文、错误输出与通知决定，按 run_id 对应到每一行；读文件不在主线程。
    val logs by androidx.compose.runtime.produceState(emptyMap<String, org.json.JSONObject>(), taskId, runs.firstOrNull()?.firedAt) {
        value = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
            runCatching {
                val rows = io.github.nanomuse.routines.ScheduledRunRecorder.journal(context).query(taskId, 30).optJSONArray("runs")
                (0 until (rows?.length() ?: 0)).mapNotNull { rows?.optJSONObject(it) }.associateBy { it.optString("run_id") }
            }.getOrDefault(emptyMap())
        }
    }

    Scaffold(
        topBar = {
            io.github.nanomuse.ui.muse.MuseTopAppBar( // nanoMuse: Muse's bar (drop-in for TopAppBar)
                title = {
                    Column {
                        Text(
                            stringResource(R.string.scheduled_task_runs_title),
                            fontWeight = FontWeight.Bold,
                            fontSize = 18.sp,
                        )
                        if (task != null && task.label.isNotBlank()) {
                            Text(
                                task.label,
                                fontSize = 12.sp,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                            )
                        }
                    }
                },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(
                            Icons.AutoMirrored.Filled.ArrowBack,
                            contentDescription = stringResource(R.string.back),
                        )
                    }
                },
            )
        },
    ) { padding ->
        if (runs.isEmpty()) {
            EmptyRuns(padding)
            return@Scaffold
        }
        LazyColumn(
            modifier = Modifier.fillMaxSize().padding(padding),
            contentPadding = PaddingValues(vertical = 8.dp),
        ) {
            items(runs, key = { it.firedAt }) { run ->
                RunRow(run = run, log = run.runId?.let(logs::get), onOpenSession = onOpenSession)
            }
        }
    }
}

@Composable
private fun EmptyRuns(padding: PaddingValues) {
    Box(
        modifier = Modifier.fillMaxSize().padding(padding).padding(32.dp),
        contentAlignment = Alignment.Center,
    ) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Icon(
                Icons.Outlined.History,
                contentDescription = null,
                modifier = Modifier.size(64.dp),
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Spacer(Modifier.height(16.dp))
            Text(
                stringResource(R.string.scheduled_task_runs_empty),
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                textAlign = androidx.compose.ui.text.style.TextAlign.Center,
            )
        }
    }
}

@Composable
private fun RunRow(run: ScheduledRun, log: org.json.JSONObject?, onOpenSession: (String) -> Unit) {
    val tappable = run.sessionId != null
    // nanoMuse: 有结果全文时点按展开；会话入口移到行尾按钮。
    val result = log?.takeIf { it.has("result") && !it.isNull("result") }?.optString("result")?.takeIf { it.isNotBlank() }
    var expanded by androidx.compose.runtime.saveable.rememberSaveable(run.firedAt) { androidx.compose.runtime.mutableStateOf(false) }
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .then(if (result != null) Modifier.clickable { expanded = !expanded }
                else if (tappable) Modifier.clickable { onOpenSession(run.sessionId!!) } else Modifier)
            .padding(horizontal = 16.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(
            imageVector = if (run.outcome == "unknown") Icons.Outlined.History else if (run.ok) Icons.Filled.CheckCircle else Icons.Filled.Error, // nanoMuse: 未知不显示成已验证成功。
            contentDescription = null,
            tint = if (run.outcome == "unknown") MaterialTheme.colorScheme.onSurfaceVariant else if (run.ok) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.error,
            modifier = Modifier.size(20.dp),
        )
        Spacer(Modifier.width(12.dp))
        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(
                text = formatRunTime(run.firedAt),
                fontWeight = FontWeight.Medium,
                fontSize = 14.sp,
            )
            // nanoMuse: [GH#557] the time this run was scheduled for, when
            // the firing carried one; runs started by hand carry none.
            run.scheduledForMs?.let { scheduledFor ->
                Text(
                    text = stringResource(
                        R.string.nm_scheduled_task_runs_scheduled_for,
                        formatRunClock(scheduledFor),
                    ),
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    fontSize = 12.sp,
                )
            }
            val preview = result ?: run.preview
            if (run.outcome == "unknown") Text(stringResource(R.string.nm_task_outcome_unknown),
                color = MaterialTheme.colorScheme.onSurfaceVariant, fontSize = 12.sp) // nanoMuse
            if (!preview.isNullOrBlank()) {
                Text(
                    text = preview,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    fontSize = 12.sp,
                    maxLines = if (expanded) Int.MAX_VALUE else 3,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            // nanoMuse: 退出码、错误输出的最后一行、没有发通知的原因。
            val details = listOfNotNull(
                run.exitCode?.let { stringResource(R.string.nm_sched_run_exit, it) },
                log?.optString("stderr_tail")?.lines()?.lastOrNull { it.isNotBlank() }?.trim()?.take(160)
                    ?.takeIf { run.outcome == "failure" || expanded }?.let { stringResource(R.string.nm_sched_run_stderr, it) },
                log?.takeIf { it.has("notified") && !it.optBoolean("notified") }?.optString("notify_suppressed_reason")
                    ?.let { quietReason(it) }?.let { stringResource(R.string.nm_sched_run_not_notified, it) },
            )
            if (details.isNotEmpty()) Text(details.joinToString(" · "), color = MaterialTheme.colorScheme.onSurfaceVariant,
                fontSize = 11.sp, maxLines = if (expanded) Int.MAX_VALUE else 2, overflow = TextOverflow.Ellipsis)
        }
        if (tappable) {
            Spacer(Modifier.width(8.dp))
            IconButton(onClick = { onOpenSession(run.sessionId!!) }, modifier = Modifier.size(32.dp)) {
                Icon(
                    Icons.AutoMirrored.Filled.KeyboardArrowRight,
                    contentDescription = stringResource(R.string.scheduled_task_runs_open_session),
                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.size(20.dp),
                )
            }
        }
    }
}

// nanoMuse: 日志里 notify_suppressed_reason 的人话。
@Composable
private fun quietReason(code: String): String? = when (code) {
    "empty" -> stringResource(R.string.nm_sched_quiet_empty)
    "unchanged" -> stringResource(R.string.nm_sched_quiet_unchanged)
    "rate_limited" -> stringResource(R.string.nm_sched_quiet_rate)
    "debug" -> stringResource(R.string.nm_sched_quiet_debug)
    "policy_never", "policy_on_failure" -> stringResource(R.string.nm_sched_quiet_policy)
    "failure_alert" -> stringResource(R.string.nm_sched_quiet_failure)
    else -> null
}

private fun formatRunTime(ms: Long): String =
    SimpleDateFormat("MMM d, HH:mm:ss", Locale.getDefault()).format(Date(ms))

// nanoMuse: [GH#557] the wall-clock time a run was scheduled for.
private fun formatRunClock(ms: Long): String =
    SimpleDateFormat("HH:mm", Locale.getDefault()).format(Date(ms))
