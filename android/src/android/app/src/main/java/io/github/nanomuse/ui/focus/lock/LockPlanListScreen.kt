package io.github.nanomuse.ui.focus.lock

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Add
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.openminis.app.R
import io.github.nanomuse.focus.lock.*
import io.github.nanomuse.ui.focus.FocusPanel
import io.github.nanomuse.ui.focus.FocusUi
import io.github.nanomuse.ui.focus.formatFocusDuration
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.catch
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.UUID

/** 计划复用专注的页头与卡片，编辑只在当前子页内展开。 */
@Composable
fun LockPlanListScreen(store: LockStore, bottomInset: Dp = 0.dp) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var hasError by remember { mutableStateOf(false) }
    val plans by remember(store) { store.observePlans().catch { if (it is CancellationException) throw it; hasError=true } }.collectAsState(emptyList())
    val runs by remember(store) { store.observeRuns().catch { if (it is CancellationException) throw it; hasError=true } }.collectAsState(emptyList())
    var editing by remember { mutableStateOf<LockPlan?>(null) }
    var isNew by remember { mutableStateOf(false) }
    var isBusy by remember { mutableStateOf(false) }
    var isReady by remember { mutableStateOf(false) }
    var now by remember { mutableLongStateOf(System.currentTimeMillis()) }
    LaunchedEffect(store) {
        while (true) {
            isReady=withContext(Dispatchers.IO) { LockPermissions.read(context).isReady }
            now=System.currentTimeMillis(); delay(2000)
        }
    }
    val activeIds=runs.filter { it.status==LockRunStatus.ACTIVE }.flatMap { it.planIds }.toSet()
    val edit=editing
    if (edit!=null) {
        BackHandler(enabled=!isBusy) { editing=null }
        LockPlanEditScreen(edit, store, isNew, edit.id in activeIds, isReady, isBusy, hasError, bottomInset,
            onCancel={editing=null;hasError=false}, onSave={next ->
                if (!isBusy) { isBusy=true;hasError=false;scope.launch {
                    try { store.savePlan(next,if(isNew) null else edit.revision); editing=null; LockController.requestEvaluation(context) }
                    catch(cancelled:CancellationException) { throw cancelled }
                    catch(_:Exception) { hasError=true }
                    finally { isBusy=false }
                } }
            }, onDelete={
                if(!isBusy) { isBusy=true;hasError=false;scope.launch {
                    try { store.deletePlan(edit.id,edit.revision);editing=null;LockController.requestEvaluation(context) }
                    catch(cancelled:CancellationException) { throw cancelled }
                    catch(_:Exception) { hasError=true }
                    finally { isBusy=false }
                } }
            })
        return
    }
    val completed=runs.filter { it.status!=LockRunStatus.ACTIVE }.flatMap { it.occurrenceIds }.toSet()
    val next=LockPlanEvaluator.nextWindow(plans,now,excludeOccurrenceIds=completed)
    LazyColumn(contentPadding=PaddingValues(20.dp,16.dp,20.dp,bottomInset+24.dp),verticalArrangement=Arrangement.spacedBy(14.dp)) {
        item { FocusPanel {
            Text(stringResource(R.string.nm_lock_plan_intro))
            next?.let { Text(stringResource(R.string.nm_lock_next_start,Instant.ofEpochMilli(it.start).atZone(ZoneId.systemDefault())
                .format(DateTimeFormatter.ofPattern("EEE HH:mm"))),style=MaterialTheme.typography.titleMedium) }
            Button(onClick={isNew=true;hasError=false;editing=LockPlan(UUID.randomUUID().toString(),"",isEnabled=false,ownerKey=store.ownerKey)}) {
                Icon(Icons.Outlined.Add,null);Text(stringResource(R.string.nm_lock_plan_add))
            }
            if(!isReady) TextButton(onClick={FocusUi.view.value="lock-permissions"}) { Text(stringResource(R.string.nm_lock_permissions)) }
        } }
        if(hasError) item { Text(stringResource(R.string.nm_lock_plan_conflict),color=MaterialTheme.colorScheme.error) }
        if(plans.isEmpty()) item { Text(stringResource(R.string.nm_lock_plan_empty)) }
        items(plans,key={it.id}) { plan -> FocusPanel {
            Row {
                Column(Modifier.weight(1f)) {
                    Text(plan.name,style=MaterialTheme.typography.titleMedium)
                    Text(plan.days.sorted().joinToString(" · ") { day -> java.time.DayOfWeek.of(day).getDisplayName(java.time.format.TextStyle.SHORT,java.util.Locale.getDefault()) })
                    Text(plan.ranges.joinToString(" · ") { lockMinute(it.startMinute)+" → "+lockMinute(it.endMinute) })
                    Text(stringResource(R.string.nm_lock_weekly_time,formatFocusDuration(plan.weeklyMinutes*60_000L)),style=MaterialTheme.typography.bodySmall)
                }
                Switch(checked=plan.isEnabled,enabled=!isBusy && plan.id !in activeIds && (isReady || plan.isEnabled),onCheckedChange={enabled ->
                    isBusy=true;hasError=false;scope.launch {
                        try {
                            if(enabled) check(LockPermissions.read(context).isReady)
                            store.savePlan(plan.copy(isEnabled=enabled),plan.revision);LockController.requestEvaluation(context)
                        } catch(cancelled:CancellationException) { throw cancelled }
                        catch(_:Exception) { hasError=true }
                        finally { isBusy=false }
                    }
                })
            }
            if(plan.id in activeIds) Text(stringResource(R.string.nm_lock_plan_active))
            OutlinedButton(enabled=!isBusy,onClick={isNew=false;hasError=false;editing=plan}) { Text(stringResource(R.string.nm_lock_plan_edit)) }
        } }
    }
}

/** 时间仅用于展示，持久化仍使用本地分钟数。 */
internal fun lockMinute(value: Int): String = "%02d:%02d".format(value/60,value%60)
