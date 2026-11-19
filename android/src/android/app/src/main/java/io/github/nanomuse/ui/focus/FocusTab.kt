package io.github.nanomuse.ui.focus

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.unit.*
import androidx.lifecycle.repeatOnLifecycle
import com.openminis.app.R
import com.openminis.app.ui.theme.ChatColors
import io.github.nanomuse.account.AccountData
import io.github.nanomuse.focus.*
import io.github.nanomuse.todo.*
import io.github.nanomuse.ui.home.MuseTones
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.catch
import java.time.*
import java.time.format.DateTimeFormatter
import java.util.UUID

/** 计时显示局部刷新，完整历史用稳定ID惰性加载。 */
@OptIn(ExperimentalLayoutApi::class)
@Composable
fun FocusTab(header:@Composable ()->Unit,bottomInset:Dp=0.dp) {
    val context=LocalContext.current
    val epoch by AccountData.epoch.collectAsState()
    key(epoch) {
        val stores=remember(epoch) { runCatching { FocusStore.get(context) to TodoStore.get(context) }.getOrNull() }
        if(stores==null) Column { header();Text(stringResource(R.string.nm_focus_error),Modifier.padding(24.dp)) }
        else FocusPage(stores.first,stores.second,header,bottomInset)
    }
}

/** 账号代次改变时重建页面草稿，不能把上一个账号输入带到新账号。 */
@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun FocusPage(store:FocusStore,todo:TodoStore,header:@Composable ()->Unit,bottomInset:Dp) {
    val context=LocalContext.current
    var failed by remember(store) { mutableStateOf(false) }
    var reload by remember { mutableIntStateOf(0) }
    val rows by remember(store,reload) { store.observe().catch { if(it is CancellationException) throw it;failed=true } }.collectAsState(emptyList())
    val tasks by remember(todo,reload) { todo.observeTasks().catch { if(it is CancellationException) throw it;failed=true } }.collectAsState(emptyList())
    val locks=remember(store) { io.github.nanomuse.focus.lock.LockStore.get(context) }
    val lockRuns by remember(locks,reload) { locks.observeRuns().catch { if(it is CancellationException) throw it;failed=true } }.collectAsState(emptyList())
    val lockBySession=remember(lockRuns) { lockRuns.associateBy { it.sessionId } }
    val view by FocusUi.view.collectAsState()
    if(view in setOf("lock-permissions","lock-whitelist","lock-settings","lock-plans")) {
        Column(Modifier.fillMaxSize().background(ChatColors.background)) {
            header()
            when(view) {
                "lock-plans" -> io.github.nanomuse.ui.focus.lock.LockPlanListScreen(locks,bottomInset)
                "lock-permissions" -> io.github.nanomuse.ui.focus.lock.LockPermissionsScreen(bottomInset)
                "lock-whitelist" -> io.github.nanomuse.ui.focus.lock.LockWhitelistScreen(locks,bottomInset)
                else -> io.github.nanomuse.ui.focus.lock.LockSettingsScreen(store,bottomInset)
            }
        }
        return
    }
    val pendingTask by FocusUi.taskId.collectAsState()
    val pendingReflection by io.github.nanomuse.ui.home.HomeBus.focusReflection.collectAsState()
    var chosenTask by rememberSaveable { mutableStateOf<String?>(null) }
    var mode by rememberSaveable { mutableStateOf("pomodoro") }
    var minutes by rememberSaveable { mutableStateOf("25") }
    var isForced by rememberSaveable { mutableStateOf(false) }
    var picker by remember { mutableStateOf(false) }
    var deleting by remember { mutableStateOf<FocusSession?>(null) }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf(false) }
    var spans by remember(store) { mutableStateOf<List<FocusSpan>>(emptyList()) }
    val scope=rememberCoroutineScope()
    val backgrounds=remember(store) { FocusBackdropStore(context,store.ownerKey,store.ownerEpoch) }
    var showBackgrounds by remember { mutableStateOf(false) }
    var backgroundRevision by remember { mutableIntStateOf(0) }
    var selectedBackground by remember { mutableStateOf<java.io.File?>(null) }
    LaunchedEffect(backgroundRevision) {
        try { selectedBackground=backgrounds.file(backgrounds.selected()) }
        catch(cancelled:CancellationException) { throw cancelled }
        catch(_:Exception) { error=true }
    }
    var exportOwner by remember { mutableStateOf<Pair<String,Long>?>(null) }
    val exporter=rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument("application/json")) { uri ->
        if(uri!=null && exportOwner==Pair(store.ownerKey,store.ownerEpoch)) scope.launch {
            try {
                val json=store.exportJson()
                withContext(Dispatchers.IO) { AccountData.withTodoOwnerMutation(store.ownerKey,store.ownerEpoch) {
                    checkNotNull(context.contentResolver.openOutputStream(uri,"wt")).bufferedWriter().use { it.write(json) }
                } }
                android.widget.Toast.makeText(context,R.string.nm_focus_exported,android.widget.Toast.LENGTH_SHORT).show()
            } catch(cancelled:CancellationException) { throw cancelled } catch(_:Exception) { error=true }
        }
    }
    val exportRequested by FocusUi.exportRequested.collectAsState()
    LaunchedEffect(exportRequested) { if(exportRequested) {
        FocusUi.exportRequested.value=false;exportOwner=Pair(store.ownerKey,store.ownerEpoch)
        exporter.launch("nanomuse-focus-${LocalDate.now()}.json")
    } }
    // 首次开始先问通知权限，回答之后再开表；否则全屏计时会盖住系统授权框。
    var askedNotifications by rememberSaveable { mutableStateOf(false) }
    var startAfterPermission by remember { mutableStateOf(false) }
    var permissionAnswers by remember { mutableIntStateOf(0) }
    val notificationPermission=rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { permissionAnswers++ }
    val active=rows.firstOrNull { it.status in setOf("running","paused") }
    val task=tasks.firstOrNull { it.id==chosenTask }
    // 账号切换由外层key(epoch)重建草稿；这里不再清空，否则每次切回本页都会丢掉已输入的标题和已选任务。
    LaunchedEffect(pendingTask) { pendingTask?.let { chosenTask=it;FocusUi.taskId.value=null } }
    LaunchedEffect(store,reload,rows) {
        try { store.refresh();spans=store.spans() }
        catch(cancelled:CancellationException) { throw cancelled }
        catch(_:Exception) { failed=true }
    }
    fun perform(action:String,row:FocusSession?=active) {
        if(busy) return
        // 直接读取请求状态，覆盖Compose尚未重组时再次点击删除的窗口。
        if(action=="delete" && io.github.nanomuse.ui.home.HomeBus.focusReflection.value!=null) return
        val duration=minutes.toIntOrNull()
        if(action=="start" && (duration==null || duration !in 1..180 || (task==null && mode!="break"))) { error=true;return }
        if(action=="start" && !askedNotifications && android.os.Build.VERSION.SDK_INT>=33 &&
            androidx.core.content.ContextCompat.checkSelfPermission(context,android.Manifest.permission.POST_NOTIFICATIONS)!=android.content.pm.PackageManager.PERMISSION_GRANTED) {
            askedNotifications=true;startAfterPermission=true
            notificationPermission.launch(android.Manifest.permission.POST_NOTIFICATIONS)
            return
        }
        busy=true;error=false
        // 专注都挂在待办上；只有休息不需要任务，标题用模式名。
        val startTitle=task?.title ?: context.getString(modeLabel(mode))
        scope.launch {
            try {
                if(action=="start" && isForced) {
                    // 强制正计时以正计时上限为截止，用户在锁页主动结束。
                    val lockMs=if(mode=="stopwatch") FocusStore.MAX_SESSION_MS else (duration ?: 25)*60_000L
                    io.github.nanomuse.focus.lock.LockController.startManual(context,
                        startTitle,task?.id,lockMs,mode) { sessionId ->
                        backgrounds.bind(sessionId)
                    }
                    return@launch
                }
                val saved=store.command(action,UUID.randomUUID().toString(),row?.id,row?.revision,startTitle,task?.id,mode,duration ?: 25)
                deleting=null
                if(action=="start") {
                    backgrounds.bind(saved.id)
                    FocusImmersiveActivity.open(context,store.ownerKey,saved.id)
                }
            }
            catch(cancelled:CancellationException) { throw cancelled }
            catch(_:Exception) { error=true }
            finally { busy=false }
        }
    }
    LaunchedEffect(permissionAnswers) { if(permissionAnswers>0 && startAfterPermission) { startAfterPermission=false;perform("start",null) } }
    Column(Modifier.fillMaxSize().background(ChatColors.background).imePadding()) {
        header()
        LazyColumn(Modifier.weight(1f),contentPadding=PaddingValues(start=20.dp,end=20.dp,top=14.dp,bottom=bottomInset+24.dp),verticalArrangement=Arrangement.spacedBy(14.dp)) {
            if(failed || error) item { Text(stringResource(R.string.nm_focus_error),color=MaterialTheme.colorScheme.error)
                TextButton(onClick={failed=false;error=false;reload++}) { Text(stringResource(R.string.nm_focus_retry)) } }
            if(view=="timer") {
                item {
                    Surface(onClick={showBackgrounds=true},shape=RoundedCornerShape(26.dp)) {
                        Box(Modifier.fillMaxWidth().height(186.dp)) {
                            FocusLandscape(Modifier.fillMaxSize())
                            selectedBackground?.let { coil.compose.AsyncImage(it,null,Modifier.fillMaxSize(),contentScale=ContentScale.Crop) }
                            Box(Modifier.fillMaxSize().background(androidx.compose.ui.graphics.Brush.verticalGradient(listOf(
                                androidx.compose.ui.graphics.Color.Transparent,androidx.compose.ui.graphics.Color.Black.copy(alpha=.55f)))))
                            Column(Modifier.align(Alignment.BottomStart).padding(22.dp),verticalArrangement=Arrangement.spacedBy(8.dp)) {
                                Text(stringResource(R.string.nm_focus_intro),style=MaterialTheme.typography.headlineSmall,fontWeight=FontWeight.SemiBold,color=androidx.compose.ui.graphics.Color.White)
                                Text(stringResource(R.string.nm_focus_choose_background),style=MaterialTheme.typography.labelLarge,color=androidx.compose.ui.graphics.Color.White)
                            }
                        }
                    }
                }
                item { FocusPanel {
                    if(active!=null) {
                        Text(active.title,style=MaterialTheme.typography.titleLarge,fontWeight=FontWeight.SemiBold)
                        Text(stringResource(modeLabel(active.mode)),color=MaterialTheme.colorScheme.onSurfaceVariant)
                        FocusClock(active,store)
                        Button(onClick={FocusImmersiveActivity.open(context,store.ownerKey,active.id)},modifier=Modifier.fillMaxWidth()) {
                            Icon(Icons.Outlined.Fullscreen,null);Spacer(Modifier.width(8.dp));Text(stringResource(R.string.nm_focus_enter_fullscreen))
                        }
                        FlowRow(horizontalArrangement=Arrangement.spacedBy(12.dp),verticalArrangement=Arrangement.spacedBy(8.dp)) {
                            FilledTonalButton(enabled=!busy,onClick={perform(if(active.status=="paused") "resume" else "pause")}) {
                                Text(stringResource(if(active.status=="paused") R.string.nm_focus_resume else R.string.nm_focus_pause)) }
                            OutlinedButton(enabled=!busy,onClick={perform("finish")}) { Text(stringResource(R.string.nm_focus_finish)) }
                        }
                    } else {
                        FlowRow(horizontalArrangement=Arrangement.spacedBy(8.dp)) {
                            listOf("pomodoro","stopwatch","break").forEach { choice -> FilterChip(selected=mode==choice,onClick={mode=choice;minutes=if(choice=="break") "5" else "25"},label={Text(stringResource(modeLabel(choice)))}) }
                        }
                        OutlinedButton(onClick={picker=true},modifier=Modifier.fillMaxWidth()) { Icon(Icons.Outlined.Checklist,null);Spacer(Modifier.width(8.dp));Text(task?.title ?: stringResource(R.string.nm_focus_choose_task)) }
                        if(mode!="stopwatch") {
                            FlowRow(horizontalArrangement=Arrangement.spacedBy(8.dp)) { (if(mode=="break") listOf(5,10,15,20) else listOf(5,25,45,60)).forEach { value -> FilterChip(selected=minutes==value.toString(),onClick={minutes=value.toString()},label={Text(stringResource(R.string.nm_focus_minutes,value))}) } }
                            OutlinedTextField(minutes,{minutes=it.filter(Char::isDigit).take(3)},label={Text(stringResource(R.string.nm_focus_custom_minutes))},singleLine=true,modifier=Modifier.fillMaxWidth())
                        }
                        io.github.nanomuse.ui.focus.lock.LockManualControls(isForced,true,{isForced=it})
                        Button(enabled=!busy && !failed && (task!=null || mode=="break"),onClick={perform("start",null)},modifier=Modifier.fillMaxWidth().heightIn(min=52.dp),shape=RoundedCornerShape(18.dp)) {
                            Icon(Icons.Outlined.PlayArrow,null);Spacer(Modifier.width(8.dp));Text(stringResource(R.string.nm_focus_start)) }
                    }
                    if(busy) LinearProgressIndicator(Modifier.fillMaxWidth())
                } }
                item { Text(stringResource(R.string.nm_focus_timer_hint),style=MaterialTheme.typography.bodySmall,color=MaterialTheme.colorScheme.onSurfaceVariant) }
                item { FocusPanel { Text(stringResource(R.string.nm_focus_today),style=MaterialTheme.typography.titleMedium)
                    Text(formatFocusDuration(FocusStatistics.duration(spans,LocalDate.now(),LocalDate.now().plusDays(1))),style=MaterialTheme.typography.headlineMedium)
                    TextButton(onClick={FocusUi.view.value="history"}) { Text(stringResource(R.string.nm_focus_history)) } } }
                item { Text(stringResource(R.string.nm_focus_recent),style=MaterialTheme.typography.titleMedium) }
                items(rows.filter { it.status=="finished" }.take(3),key={it.id}) { row ->
                    FocusRecord(row,lockBySession[row.id],isOpening=pendingReflection?.sessionId==row.id,
                        canOpen=!busy && pendingReflection==null,onDelete={
                        if(!busy && io.github.nanomuse.ui.home.HomeBus.focusReflection.value==null) deleting=row
                    },onReflect={
                        if(!busy) io.github.nanomuse.ui.home.HomeBus.showFocusReflection(FocusReflectionRequest(store.ownerKey,store.ownerEpoch,row.id))
                    })
                }
            } else if(view=="history") {
                item { Text(stringResource(R.string.nm_focus_history_hint),color=MaterialTheme.colorScheme.onSurfaceVariant) }
                if(rows.none { it.status=="finished" }) item { Text(stringResource(R.string.nm_focus_empty)) }
                items(rows.filter { it.status=="finished" },key={it.id}) { row ->
                    FocusRecord(row,lockBySession[row.id],isOpening=pendingReflection?.sessionId==row.id,
                        canOpen=!busy && pendingReflection==null,onDelete={
                        if(!busy && io.github.nanomuse.ui.home.HomeBus.focusReflection.value==null) deleting=row
                    },onReflect={
                        if(!busy) io.github.nanomuse.ui.home.HomeBus.showFocusReflection(FocusReflectionRequest(store.ownerKey,store.ownerEpoch,row.id))
                    })
                }
            } else {
                item { FocusStats(rows,spans,lockRuns,tasks) }
            }
        }
    }
    if(showBackgrounds) FocusBackdropPicker(backgrounds,{showBackgrounds=false},{backgroundRevision++})
    // 选择器里可以就地新建待办，新建的待办直接选中，并出现在待办列表里。
    if(picker) FocusTaskPicker(tasks,todo,onPick={chosenTask=it;picker=false},onDismiss={picker=false})
    deleting?.let { row -> AlertDialog(onDismissRequest={if(!busy) deleting=null},title={Text(stringResource(R.string.nm_focus_delete))},
        text={Text(stringResource(R.string.nm_focus_delete_hint))},confirmButton={TextButton(enabled=!busy && pendingReflection==null,onClick={perform("delete",row)}){Text(stringResource(R.string.nm_focus_delete))}},
        dismissButton={TextButton(enabled=!busy,onClick={deleting=null}){Text(stringResource(R.string.nm_todo_close))}}) }
}

/** 秒表只重组自己的区域，到达目标才请求持久结算。 */
@Composable
private fun FocusClock(row:FocusSession,store:FocusStore) {
    val context=LocalContext.current
    var elapsed by remember(row) { mutableLongStateOf(FocusStore.elapsed(row,context)) }
    val lifecycleOwner=androidx.lifecycle.compose.LocalLifecycleOwner.current
    LaunchedEffect(row.id,row.revision) {
        // 只在页面可见时走表。应用在后台时由闹钟结算并发“已结束”通知；
        // 若这里在后台先结算，会把还没送达的闹钟取消，计时就无声结束。
        lifecycleOwner.lifecycle.repeatOnLifecycle(androidx.lifecycle.Lifecycle.State.STARTED) {
            while(row.status=="running") {
                elapsed=FocusStore.elapsed(row,context)
                if(elapsed>=row.targetMs) {
                    try { store.refresh() } catch(cancelled:CancellationException) { throw cancelled }
                    catch(_:Exception) { delay(2000);continue }
                    break
                }
                // 对齐到下一个整秒再刷新：固定等1000毫秒会随处理耗时逐渐漂移，显示上偶尔跳过一秒。
                delay(1000-elapsed%1000+10)
            }
        }
    }
    val shown=if(row.mode=="stopwatch") elapsed else (row.targetMs-elapsed).coerceAtLeast(0)
    Column(Modifier.fillMaxWidth().padding(vertical=24.dp),horizontalAlignment=Alignment.CenterHorizontally) {
        Text(formatFocusDuration(shown),fontSize=44.sp,fontWeight=FontWeight.Medium)
        // 正计时没有目标时长，进度条没有意义；改为显示开始时刻。
        if(row.mode=="stopwatch") Text(stringResource(R.string.nm_focus_started_at,
            java.time.Instant.ofEpochMilli(row.startedAt).atZone(java.time.ZoneId.systemDefault()).toLocalTime().withNano(0).toString().take(5)),
            Modifier.padding(top=12.dp),color=MaterialTheme.colorScheme.onSurfaceVariant)
        else LinearProgressIndicator(progress={ (elapsed.toFloat()/row.targetMs).coerceIn(0f,1f) },modifier=Modifier.fillMaxWidth().padding(top=20.dp))
        if(row.status=="paused") Text(stringResource(R.string.nm_focus_paused),Modifier.padding(top=12.dp))
    }
}

/** 卡片采用App相同圆角与留白。 */
@Composable
internal fun FocusPanel(content:@Composable ColumnScope.()->Unit) {
    Surface(shape=RoundedCornerShape(22.dp),color=MuseTones.surface,border=androidx.compose.foundation.BorderStroke(1.dp,MuseTones.hairline)) {
        Column(Modifier.fillMaxWidth().padding(18.dp),verticalArrangement=Arrangement.spacedBy(12.dp),content=content)
    }
}

@Composable
private fun FocusRecord(row:FocusSession,lock:io.github.nanomuse.focus.lock.LockRun?,isOpening:Boolean,canOpen:Boolean,onDelete:()->Unit,onReflect:()->Unit) { FocusPanel {
    Row(verticalAlignment=Alignment.CenterVertically) { Text(row.title,Modifier.weight(1f),style=MaterialTheme.typography.titleMedium)
        IconButton(onClick=onDelete,enabled=canOpen) { Icon(Icons.Outlined.DeleteOutline,stringResource(R.string.nm_focus_delete)) } }
    Text(formatFocusRange(row.startedAt,row.endedAt ?: row.startedAt),style=MaterialTheme.typography.bodySmall)
    Text(formatFocusDuration(row.elapsedMs)+" · "+stringResource(modeLabel(row.mode)),fontWeight=FontWeight.SemiBold)
    if(row.groupName.isNotBlank()) Text(row.groupName,style=MaterialTheme.typography.labelMedium)
    io.github.nanomuse.ui.focus.lock.LockRecordBadge(lock)
    if(row.mode!="break") TextButton(onClick=onReflect,enabled=canOpen) {
        if(isOpening) CircularProgressIndicator(Modifier.size(18.dp),strokeWidth=2.dp)
        else Icon(Icons.Outlined.EditNote,null,Modifier.size(20.dp))
        Spacer(Modifier.width(8.dp))
        Text(stringResource(R.string.nm_focus_reflection))
    }
} }

internal fun modeLabel(mode:String):Int=when(mode){"stopwatch"->R.string.nm_focus_stopwatch;"break"->R.string.nm_focus_break;else->R.string.nm_focus_pomodoro}
internal fun formatFocusDuration(ms:Long):String { val seconds=ms.coerceAtLeast(0)/1000;return if(seconds>=3600) "%d:%02d:%02d".format(seconds/3600,seconds/60%60,seconds%60) else "%02d:%02d".format(seconds/60,seconds%60) }
internal fun formatFocusRange(start:Long,end:Long):String { val format=DateTimeFormatter.ofPattern("MM-dd HH:mm");val zone=ZoneId.systemDefault();return Instant.ofEpochMilli(start).atZone(zone).format(format)+" → "+Instant.ofEpochMilli(end).atZone(zone).format(format) }
