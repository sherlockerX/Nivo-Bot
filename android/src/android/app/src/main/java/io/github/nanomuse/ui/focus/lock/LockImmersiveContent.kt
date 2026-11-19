package io.github.nanomuse.ui.focus.lock

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Lock
import androidx.compose.material.icons.outlined.Phone
import androidx.compose.material.icons.outlined.Stop
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.repeatOnLifecycle
import coil.compose.AsyncImage
import com.openminis.app.R
import io.github.nanomuse.focus.FocusStore
import io.github.nanomuse.focus.lock.*
import io.github.nanomuse.ui.focus.FocusLandscape
import io.github.nanomuse.ui.focus.formatFocusDuration
import kotlinx.coroutines.*
import java.io.File

/**
 * 现有全屏窗口的锁定形态，不提供普通计时的暂停和返回入口。
 * 强制正计时没有结束时刻，时钟向上计，并提供"结束专注"：确认后按真实计时保存并解除锁定。
 */
@OptIn(ExperimentalLayoutApi::class)
@Composable
fun LockImmersiveContent(store: LockStore, run: LockRun, title: String, background: File?, keepScreen: (Boolean) -> Unit,
    isStopwatch: Boolean = false) {
    val context = LocalContext.current
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    val scope = rememberCoroutineScope()
    val whitelist by remember(store) { store.observeWhitelist() }.collectAsState(emptySet())
    var apps by remember(store) { mutableStateOf<List<InstalledApp>>(emptyList()) }
    var remaining by remember(run) { mutableLongStateOf(run.checkpointRemainingMs) }
    var failed by remember { mutableStateOf(false) }
    var confirmEnd by remember { mutableStateOf(false) }
    var ending by remember { mutableStateOf(false) }
    BackHandler { }
    DisposableEffect(Unit) { keepScreen(false); onDispose { keepScreen(false) } }
    LaunchedEffect(store, whitelist) { apps = InstalledApps.load(context).filter { it.packageName in whitelist && it.isLaunchable && !it.isForbidden } }
    LaunchedEffect(run) { lifecycle.repeatOnLifecycle(Lifecycle.State.STARTED) {
        while (true) {
            val boot = FocusStore.boot(context).takeIf { it >= 0 } ?: LockRun.PROCESS_BOOT_COUNT
            remaining = run.remaining(System.currentTimeMillis(), android.os.SystemClock.elapsedRealtime(), boot).milliseconds
            if (remaining == 0L) { LockController.requestEvaluation(context); break }
            delay(500)
        }
    } }
    fun open(packageName: String?) { scope.launch {
        try {
            if (LockController.evaluate(context)?.id != run.id) return@launch
            failed = !(if (packageName == null) InstalledApps.openDialer(context) else InstalledApps.launch(context, packageName))
        } catch (cancelled: CancellationException) { throw cancelled }
        catch (_: Exception) { failed = true }
    } }
    fun endStopwatch() {
        if (ending) return
        ending = true
        scope.launch {
            try { LockController.finishStopwatch(context, run.id) }
            catch (cancelled: CancellationException) { throw cancelled }
            catch (_: Exception) { failed = true }
            finally { ending = false }
        }
    }
    if (confirmEnd) AlertDialog(onDismissRequest = { confirmEnd = false },
        title = { Text(stringResource(R.string.nm_lock_stopwatch_end)) },
        text = { Text(stringResource(R.string.nm_lock_stopwatch_end_confirm)) },
        confirmButton = { TextButton(onClick = { confirmEnd = false; endStopwatch() }) { Text(stringResource(R.string.nm_focus_finish)) } },
        dismissButton = { TextButton(onClick = { confirmEnd = false }) { Text(stringResource(R.string.nm_cancel)) } })
    BoxWithConstraints(Modifier.fillMaxSize()) {
        val clockWidth = maxWidth.value - 48
        FocusLandscape(Modifier.fillMaxSize())
        background?.let { AsyncImage(it, null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop) }
        Box(Modifier.fillMaxSize().background(Brush.verticalGradient(listOf(Color.Black.copy(alpha = .35f), Color.Black.copy(alpha = .55f)))))
        Column(Modifier.fillMaxSize().safeDrawingPadding().padding(24.dp).verticalScroll(rememberScrollState()),
            horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
            Icon(Icons.Outlined.Lock, null, tint = Color.White)
            Text(stringResource(R.string.nm_lock_title), color = Color.White, modifier = Modifier.padding(12.dp))
            Text(title, style = MaterialTheme.typography.headlineSmall, color = Color.White, textAlign = TextAlign.Center)
            val clock = formatFocusDuration(if (isStopwatch) run.durationMs - remaining else remaining)
            val scale = androidx.compose.ui.platform.LocalDensity.current.fontScale
            Text(clock, color = Color.White, fontFamily = FontFamily.Monospace,
                fontSize = minOf(74f, clockWidth / (clock.length * .65f * scale)).sp,
                modifier = Modifier.padding(vertical = 28.dp), maxLines = 1)
            Text(stringResource(if (isStopwatch) R.string.nm_lock_stopwatch_running else R.string.nm_lock_until_end),
                color = Color.White.copy(alpha = .85f), textAlign = TextAlign.Center)
            if (isStopwatch) Button(onClick = { confirmEnd = true }, enabled = !ending,
                modifier = Modifier.padding(top = 20.dp).heightIn(min = 52.dp)) {
                Icon(Icons.Outlined.Stop, null); Spacer(Modifier.width(8.dp)); Text(stringResource(R.string.nm_lock_stopwatch_end))
            }
            Spacer(Modifier.height(32.dp))
            if (run.usesWhitelist) FlowRow(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                apps.filter { it.packageName != context.packageName }.forEach { app ->
                    FilledTonalButton(onClick = { open(app.packageName) }) {
                        val icon by produceState<android.graphics.Bitmap?>(null, app.packageName) { value = InstalledApps.loadIcon(context, app.packageName) }
                        icon?.let { Image(it.asImageBitmap(), null, Modifier.size(24.dp)); Spacer(Modifier.width(8.dp)) }
                        Text(app.label)
                    }
                }
            }
            OutlinedButton(onClick = { open(null) }, modifier = Modifier.padding(top = 16.dp)) {
                Icon(Icons.Outlined.Phone, null); Spacer(Modifier.width(8.dp)); Text(stringResource(R.string.nm_lock_dial), color = Color.White)
            }
            if (failed) Text(stringResource(R.string.nm_lock_open_app_failed), color = Color.White)
            LockEmergencyContent(store, run, dial = { open(null) })
        }
    }
}
