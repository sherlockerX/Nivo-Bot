package io.github.nanomuse.ui.focus.lock

import android.app.TimePickerDialog
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.openminis.app.R
import io.github.nanomuse.focus.lock.*
import io.github.nanomuse.todo.TodoTask
import io.github.nanomuse.todo.TodoStore
import io.github.nanomuse.ui.focus.FocusPanel
import kotlinx.coroutines.CancellationException

/** 多个日历时段使用系统时间选择器，避免用户手输时间造成不可执行的计划。 */
@OptIn(ExperimentalLayoutApi::class)
@Composable
internal fun LockPlanEditScreen(plan: LockPlan, store: LockStore, isNew: Boolean, isActive: Boolean,
    isReady: Boolean, isBusy: Boolean, hasError: Boolean, bottomInset: Dp,
    onCancel: () -> Unit, onSave: (LockPlan) -> Unit, onDelete: () -> Unit) {
    val context=LocalContext.current
    var name by remember(plan.id) { mutableStateOf(plan.name) }
    var title by remember(plan.id) { mutableStateOf(plan.title.orEmpty()) }
    var days by remember(plan.id) { mutableStateOf(plan.days) }
    var ranges by remember(plan.id) { mutableStateOf(plan.ranges.ifEmpty { listOf(TimeRange(540,565)) }) }
    var usesWhitelist by remember(plan.id) { mutableStateOf(plan.usesWhitelist) }
    var enabled by remember(plan.id) { mutableStateOf(plan.isEnabled) }
    var taskId by remember(plan.id) { mutableStateOf(plan.taskId) }
    var tasks by remember(store) { mutableStateOf<List<TodoTask>>(emptyList()) }
    var showTasks by remember { mutableStateOf(false) }
    var confirmDelete by remember { mutableStateOf(false) }
    LaunchedEffect(store) {
        try { tasks=TodoStore.get(context).tasks() }
        catch(cancelled:CancellationException) { throw cancelled }
        catch(_:Exception) { tasks=emptyList() }
    }
    val editable=!isActive && !isBusy
    fun chooseTime(index:Int,start:Boolean) {
        val range=ranges[index];val value=if(start) range.startMinute else range.endMinute
        TimePickerDialog(context,{_,hour,minute ->
            val next=hour*60+minute
            ranges=ranges.toMutableList().also { it[index]=if(start) range.copy(startMinute=next) else range.copy(endMinute=next) }
        },value/60,value%60,android.text.format.DateFormat.is24HourFormat(context)).show()
    }
    LazyColumn(contentPadding=PaddingValues(20.dp,16.dp,20.dp,bottomInset+24.dp),verticalArrangement=Arrangement.spacedBy(14.dp)) {
        item { if(isActive) Text(stringResource(R.string.nm_lock_plan_active))
            if(hasError) Text(stringResource(R.string.nm_lock_plan_conflict),color=MaterialTheme.colorScheme.error)
        }
        item { FocusPanel {
            OutlinedTextField(name,{name=it.take(500)},enabled=editable,label={Text(stringResource(R.string.nm_lock_plan_name))},modifier=Modifier.fillMaxWidth())
            FlowRow(horizontalArrangement=Arrangement.spacedBy(6.dp)) {
                (1..7).forEach { day -> FilterChip(selected=day in days,enabled=editable,onClick={days=if(day in days) days-day else days+day},label={
                    Text(java.time.DayOfWeek.of(day).getDisplayName(java.time.format.TextStyle.SHORT,java.util.Locale.getDefault()))
                }) }
            }
            Row { Text(stringResource(R.string.nm_lock_plan_enable),Modifier.weight(1f));Switch(enabled,enabled=editable && (isReady || enabled),onCheckedChange={enabled=it}) }
        } }
        item { FocusPanel {
            Text(stringResource(R.string.nm_lock_plan_ranges),style=MaterialTheme.typography.titleMedium)
            ranges.forEachIndexed { index,range ->
                Row(horizontalArrangement=Arrangement.spacedBy(8.dp)) {
                    OutlinedButton(enabled=editable,onClick={chooseTime(index,true)}) { Text(lockMinute(range.startMinute)) }
                    OutlinedButton(enabled=editable,onClick={chooseTime(index,false)}) { Text(lockMinute(range.endMinute)) }
                    TextButton(enabled=editable && ranges.size>1,onClick={ranges=ranges.filterIndexed { i,_ -> i!=index }}) { Text(stringResource(R.string.nm_lock_remove_range)) }
                }
                if(range.isCrossingMidnight) Text(stringResource(if(range.isWholeDay) R.string.nm_lock_whole_day else R.string.nm_lock_cross_midnight),style=MaterialTheme.typography.bodySmall)
            }
            TextButton(enabled=editable && ranges.size<LockConfigurationRules.MAX_RANGES,onClick={ranges=ranges+TimeRange(540,565)}) { Text(stringResource(R.string.nm_lock_add_range)) }
        } }
        item { FocusPanel {
            Row { Text(stringResource(R.string.nm_lock_use_whitelist),Modifier.weight(1f));Switch(usesWhitelist,enabled=editable,onCheckedChange={usesWhitelist=it}) }
            OutlinedTextField(title,{title=it.take(500)},enabled=editable,label={Text(stringResource(R.string.nm_lock_plan_focus_title))},modifier=Modifier.fillMaxWidth())
            OutlinedButton(enabled=editable,onClick={showTasks=true}) { Text(tasks.firstOrNull { it.id==taskId }?.title ?: stringResource(R.string.nm_lock_plan_task)) }
            if(taskId!=null) TextButton(enabled=editable,onClick={taskId=null}) { Text(stringResource(R.string.nm_lock_clear_task)) }
        } }
        item {
            if(isBusy) LinearProgressIndicator(Modifier.fillMaxWidth())
            Button(enabled=editable && name.isNotBlank() && days.isNotEmpty() && ranges.distinct().size==ranges.size && (!enabled || isReady),
                onClick={onSave(plan.copy(name=name.trim(),title=title.trim().takeIf { it.isNotEmpty() },days=days,ranges=ranges,
                    usesWhitelist=usesWhitelist,isEnabled=enabled,taskId=taskId))},modifier=Modifier.fillMaxWidth()) { Text(stringResource(R.string.nm_lock_save_plan)) }
            TextButton(enabled=!isBusy,onClick=onCancel) { Text(stringResource(android.R.string.cancel)) }
            if(!isNew) TextButton(enabled=editable,onClick={confirmDelete=true}) { Text(stringResource(R.string.nm_lock_delete_plan)) }
        }
    }
    if(confirmDelete) AlertDialog(onDismissRequest={confirmDelete=false},title={Text(stringResource(R.string.nm_lock_delete_plan))},
        text={Text(stringResource(R.string.nm_lock_delete_plan_hint))},confirmButton={TextButton(onClick={confirmDelete=false;onDelete()}) { Text(stringResource(R.string.nm_lock_delete_plan)) }},
        dismissButton={TextButton(onClick={confirmDelete=false}) { Text(stringResource(android.R.string.cancel)) }})
    if(showTasks) AlertDialog(onDismissRequest={showTasks=false},title={Text(stringResource(R.string.nm_lock_plan_task))},text={
        androidx.compose.foundation.lazy.LazyColumn(Modifier.heightIn(max=360.dp)) {
            tasks.filter { it.status!="done" }.forEach { task -> item(key=task.id) { TextButton(onClick={taskId=task.id;showTasks=false}) { Text(task.title) } } }
        }
    },confirmButton={TextButton(onClick={showTasks=false}) { Text(stringResource(android.R.string.cancel)) }})
}
