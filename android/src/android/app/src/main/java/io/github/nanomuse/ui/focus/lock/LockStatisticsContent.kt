package io.github.nanomuse.ui.focus.lock

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.openminis.app.R
import io.github.nanomuse.focus.FocusSession
import io.github.nanomuse.focus.FocusSpan
import io.github.nanomuse.focus.lock.*
import io.github.nanomuse.ui.focus.FocusPanel
import io.github.nanomuse.ui.focus.formatFocusDuration
import java.time.LocalDate
import java.time.ZoneId

/** 强制小计沿用专注页的日周月年范围，排除休息和删除记录。 */
@Composable
internal fun LockStatisticsContent(rows: List<FocusSession>, spans: List<FocusSpan>, runs: List<LockRun>,
    start: LocalDate, endExclusive: LocalDate) {
    val zone = ZoneId.systemDefault()
    val summary = remember(rows, spans, runs, start, endExclusive, zone) {
        LockStatistics.summarize(runs, rows.filter { it.status == "finished" && it.mode != "break" }.map { it.id }.toSet(),
            spans.map { LockMeasuredSpan(it.sessionId, it.startedAt, it.durationMs) },
            start.atStartOfDay(zone).toInstant().toEpochMilli(), endExclusive.atStartOfDay(zone).toInstant().toEpochMilli())
    }
    FocusPanel {
        Text(stringResource(R.string.nm_lock_statistics), style = MaterialTheme.typography.titleMedium)
        Text(formatFocusDuration(summary.durationMs), style = MaterialTheme.typography.headlineMedium)
        Text(stringResource(R.string.nm_lock_emergency_count, summary.emergencyCount))
        Text(stringResource(R.string.nm_lock_statistics_hint), style = MaterialTheme.typography.bodySmall)
    }
}

/** 历史卡片只展示运行账本的结果，不改普通专注的数据结构。 */
@Composable
internal fun LockRecordBadge(run: LockRun?) {
    if (run == null) return
    val label = if (run.status == LockRunStatus.EMERGENCY) R.string.nm_lock_emergency_record else R.string.nm_lock_title
    SuggestionChip(onClick = {}, label = { Text(stringResource(label)) }, enabled = false)
}
