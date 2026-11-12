package io.github.nanomuse.ui.focus

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Timer
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.openminis.app.R
import io.github.nanomuse.focus.*
import java.time.Instant
import java.time.ZoneId

/** 每日记录选择真实已结束时段，历史快照与实时目录分开显示。 */
@Composable
fun FocusMosaicPicker(records:List<FocusSession>,selected:List<String>,saved:List<FocusEntryLink>,day:Long,enabled:Boolean,onChange:(List<String>)->Unit) {
    var open by remember { mutableStateOf(false) }
    var allDays by remember { mutableStateOf(false) }
    val snapshots=remember(records,saved) {
        val current=records.filter { it.status=="finished" && it.mode!="break" }.map { FocusEntryLink(it.ownerKey,"",it.id,it.title,it.startedAt,it.endedAt ?: it.startedAt,it.elapsedMs) }
        (saved+current).distinctBy { it.sessionId }.sortedByDescending { it.startedAt }
    }
    Column(Modifier.fillMaxWidth().padding(horizontal=20.dp),verticalArrangement=Arrangement.spacedBy(8.dp)) {
        OutlinedButton(enabled=enabled,onClick={open=true},modifier=Modifier.fillMaxWidth()) {
            Icon(Icons.Outlined.Timer,null);Spacer(Modifier.width(8.dp));Text(stringResource(R.string.nm_focus_select_sessions,selected.size))
        }
        snapshots.filter { it.sessionId in selected }.forEach { row ->
            Text(row.title+" · "+formatFocusDuration(row.durationMs),style=MaterialTheme.typography.bodyMedium)
            Text(formatFocusRange(row.startedAt,row.endedAt),style=MaterialTheme.typography.bodySmall)
        }
    }
    if(open) AlertDialog(onDismissRequest={open=false},title={Text(stringResource(R.string.nm_focus_select_title))},text={
        Column {
            FilterChip(selected=allDays,onClick={allDays=!allDays},label={Text(stringResource(R.string.nm_focus_all_days))})
            val zone=ZoneId.systemDefault()
            val visible=snapshots.filter { allDays || it.sessionId in selected ||
                day in Instant.ofEpochMilli(it.startedAt).atZone(zone).toLocalDate().toEpochDay()..Instant.ofEpochMilli(it.endedAt).atZone(zone).toLocalDate().toEpochDay() }
            if(visible.isEmpty()) Text(stringResource(R.string.nm_focus_empty))
            LazyColumn(Modifier.heightIn(max=380.dp)) { items(visible,key={it.sessionId}) { row ->
                Surface(onClick={if(row.sessionId in selected) onChange(selected-row.sessionId) else if(selected.size<100) onChange(selected+row.sessionId)}) {
                    Row(Modifier.fillMaxWidth().padding(vertical=8.dp)) {
                        Checkbox(checked=row.sessionId in selected,onCheckedChange=null)
                        Column(Modifier.weight(1f)) { Text(row.title);Text(formatFocusRange(row.startedAt,row.endedAt),style=MaterialTheme.typography.bodySmall);Text(formatFocusDuration(row.durationMs)) }
                    }
                }
            } }
        }
    },confirmButton={TextButton(onClick={open=false}){Text(stringResource(R.string.nm_todo_close))}})
}
