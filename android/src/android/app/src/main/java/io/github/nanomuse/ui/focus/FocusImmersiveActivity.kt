package io.github.nanomuse.ui.focus

import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.repeatOnLifecycle
import coil.compose.AsyncImage
import com.openminis.app.R
import com.openminis.app.ui.theme.MinisTheme
import io.github.nanomuse.account.AccountData
import io.github.nanomuse.focus.FocusBackdropStore
import io.github.nanomuse.focus.FocusSession
import io.github.nanomuse.focus.FocusStore
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.launch
import java.io.File
import java.util.UUID

/** 独立专注窗口从持久会话恢复，锁屏和进程重建都不创建新的计时。 */
class FocusImmersiveActivity : ComponentActivity() {
    override fun attachBaseContext(newBase: Context) {
        super.attachBaseContext(com.openminis.app.i18n.LocaleWrap.wrap(newBase))
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        val owner = intent.getStringExtra(EXTRA_OWNER)
        val session = intent.getStringExtra(EXTRA_SESSION)
        val store = runCatching { FocusStore.get(this) }.getOrNull()
        if (store == null || store.ownerKey != owner || session.isNullOrBlank()) { finish(); return }
        setContent { MinisTheme(darkTheme = true) {
            Surface(color = Color(0xFF183E42), contentColor = Color.White) {
                ImmersiveFocus(store, session, { finish() }) { keep ->
                    if (keep) window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    else window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                }
            }
        } }
        hideSystemBars()
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) hideSystemBars()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        val hasChanged = this.intent.getStringExtra(EXTRA_SESSION) != intent.getStringExtra(EXTRA_SESSION) ||
            this.intent.getStringExtra(EXTRA_OWNER) != intent.getStringExtra(EXTRA_OWNER)
        setIntent(intent)
        if (hasChanged) recreate()
    }

    private fun hideSystemBars() {
        WindowCompat.getInsetsController(window, window.decorView).apply {
            systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            hide(WindowInsetsCompat.Type.systemBars())
        }
    }

    companion object {
        private const val EXTRA_OWNER = "focus_owner"
        private const val EXTRA_SESSION = "focus_session"
        /** 只接受已落盘会话ID，不通过Intent传递计时或任务内容。 */
        fun open(context: Context, owner: String, session: String) {
            context.startActivity(Intent(context, FocusImmersiveActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                .putExtra(EXTRA_OWNER, owner).putExtra(EXTRA_SESSION, session))
        }
    }
}

/** 视觉层只读时间，不以动画帧累计；回到前台先与持久化记录对齐。 */
@Composable
private fun ImmersiveFocus(store: FocusStore, sessionId: String, onClose: () -> Unit, keepScreen: (Boolean) -> Unit) {
    val context = androidx.compose.ui.platform.LocalContext.current
    val lifecycle = LocalLifecycleOwner.current
    val scope = rememberCoroutineScope()
    val epoch by AccountData.epoch.collectAsState()
    var failed by remember { mutableStateOf(false) }
    val rows by remember(store) { store.observe().catch { if (it is CancellationException) throw it; failed = true } }.collectAsState(initial = null)
    val row = rows?.firstOrNull { it.id == sessionId }
    val backgrounds = remember(store) { FocusBackdropStore(context, store.ownerKey, store.ownerEpoch) }
    var background by remember { mutableStateOf<File?>(null) }
    var keepOn by remember { mutableStateOf(backgrounds.keepScreenOn()) }
    var busy by remember { mutableStateOf(false) }
    var confirmFinish by remember { mutableStateOf(false) }
    var loaded by remember { mutableStateOf(false) }
    fun minimize() { scope.launch {
        try { backgrounds.rememberImmersive(null); onClose() }
        catch(cancelled:CancellationException) { throw cancelled }
        catch(_:Exception) { failed=true }
    } }
    LaunchedEffect(epoch) { if (epoch != store.ownerEpoch) onClose() }
    LaunchedEffect(store, sessionId) {
        lifecycle.lifecycle.repeatOnLifecycle(Lifecycle.State.RESUMED) {
            try { store.refresh(); background = backgrounds.backgroundFor(sessionId); loaded = true
                backgrounds.rememberImmersive(sessionId)
            }
            catch (cancelled: CancellationException) { throw cancelled }
            catch (_: Exception) { failed = true }
        }
    }
    DisposableEffect(keepOn, row?.status) {
        keepScreen(keepOn && row?.status == "running")
        onDispose { keepScreen(false) }
    }
    BackHandler(onBack = ::minimize)
    fun command(action: String) {
        val current = row ?: return
        if (busy) return
        busy = true; failed = false
        scope.launch {
            try { store.command(action, UUID.randomUUID().toString(), current.id, current.revision); confirmFinish = false }
            catch (cancelled: CancellationException) { throw cancelled }
            catch (_: Exception) { failed = true; runCatching { store.refresh() } }
            finally { busy = false }
        }
    }
    BoxWithConstraints(Modifier.fillMaxSize()) {
        FocusLandscape(Modifier.fillMaxSize())
        background?.let { AsyncImage(it, null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop) }
        Box(Modifier.fillMaxSize().background(Brush.verticalGradient(listOf(Color.Black.copy(alpha = .34f), Color.Black.copy(alpha = .20f), Color.Black.copy(alpha = .60f)))))
        val isCompact = maxHeight < 480.dp
        Column(Modifier.fillMaxSize().safeDrawingPadding().padding(horizontal = 24.dp, vertical = 16.dp)) {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                IconButton(onClick = ::minimize) { Icon(Icons.AutoMirrored.Outlined.ArrowBack, stringResource(R.string.nm_focus_minimize), tint = Color.White) }
                Text(stringResource(R.string.nm_focus_title), Modifier.weight(1f), style = MaterialTheme.typography.titleMedium, textAlign = TextAlign.Center)
                IconToggleButton(checked = keepOn, onCheckedChange = { next -> scope.launch {
                    try { backgrounds.setKeepScreenOn(next); keepOn = next }
                    catch (cancelled: CancellationException) { throw cancelled }
                    catch (_: Exception) { failed = true }
                } }) { Icon(if (keepOn) Icons.Outlined.LightMode else Icons.Outlined.Bedtime,
                    stringResource(if (keepOn) R.string.nm_focus_keep_on_enabled else R.string.nm_focus_keep_on_disabled), tint = Color.White) }
            }
            Column(Modifier.weight(1f).fillMaxWidth().verticalScroll(rememberScrollState()),
                horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
                if (row == null) {
                    if (failed || loaded && rows != null) {
                        Text(stringResource(R.string.nm_focus_error))
                        TextButton(onClick=::minimize) { Text(stringResource(R.string.nm_focus_back)) }
                    } else CircularProgressIndicator(color = Color.White)
                } else {
                    Text(row.title, style = MaterialTheme.typography.headlineSmall, textAlign = TextAlign.Center,
                        modifier = Modifier.widthIn(max = 600.dp).padding(top = if (isCompact) 8.dp else 24.dp))
                    Text(stringResource(modeLabel(row.mode)), Modifier.padding(top = 10.dp), color = Color.White.copy(alpha = .8f))
                    ImmersiveClock(row, store, if (isCompact) 60 else 82)
                    Text(stringResource(when (row.status) { "paused" -> R.string.nm_focus_paused; "finished" -> R.string.nm_focus_finished; else -> R.string.nm_focus_in_session }),
                        textAlign = TextAlign.Center, color = Color.White.copy(alpha = .85f))
                    Spacer(Modifier.height(if (isCompact) 14.dp else 42.dp))
                    if (failed) Text(stringResource(R.string.nm_focus_error), textAlign = TextAlign.Center)
                    if (busy) LinearProgressIndicator(Modifier.widthIn(max = 320.dp).fillMaxWidth())
                    if (row.status == "finished") {
                        Text(stringResource(R.string.nm_focus_finished_hint), textAlign = TextAlign.Center)
                        Button(onClick = ::minimize, modifier = Modifier.padding(top = 18.dp).heightIn(min = 52.dp)) { Text(stringResource(R.string.nm_focus_back)) }
                    } else {
                        // 状态变化重建操作区，避免按钮内容复用旧状态的组合闭包。
                        key(row.id, row.revision, row.status) {
                        Button(onClick = { command(if (row.status == "paused") "resume" else "pause") }, enabled = !busy,
                            colors = ButtonDefaults.buttonColors(containerColor = Color.White.copy(alpha = .92f), contentColor = Color(0xFF173D3F)),
                            modifier = Modifier.widthIn(max = 280.dp).fillMaxWidth().heightIn(min = 58.dp), shape = RoundedCornerShape(29.dp)) {
                            Icon(if (row.status == "paused") Icons.Outlined.PlayArrow else Icons.Outlined.Pause, null)
                            Spacer(Modifier.width(10.dp)); Text(stringResource(if (row.status == "paused") R.string.nm_focus_resume else R.string.nm_focus_pause))
                        }
                        TextButton(onClick = { confirmFinish = true }, enabled = !busy, modifier = Modifier.padding(top = 10.dp)) {
                            Text(stringResource(R.string.nm_focus_finish), color = Color.White)
                        }
                        }
                    }
                    Spacer(Modifier.height(20.dp))
                }
            }
            if (!isCompact) Text(stringResource(R.string.nm_focus_screen_hint), style = MaterialTheme.typography.bodySmall,
                textAlign = TextAlign.Center, color = Color.White.copy(alpha = .72f), modifier = Modifier.fillMaxWidth().padding(vertical = 12.dp))
        }
    }
    if (confirmFinish) AlertDialog(onDismissRequest = { if (!busy) confirmFinish = false },
        title = { Text(stringResource(R.string.nm_focus_finish)) }, text = { Text(stringResource(R.string.nm_focus_finish_confirm)) },
        confirmButton = { TextButton(enabled = !busy, onClick = { command("finish") }) { Text(stringResource(R.string.nm_focus_finish)) } },
        dismissButton = { TextButton(enabled = !busy, onClick = { confirmFinish = false }) { Text(stringResource(android.R.string.cancel)) } })
}

/** 仅钟面每秒更新，到期请求Store结算，不令整张背景反复加载。 */
@Composable
private fun ImmersiveClock(row: FocusSession, store: FocusStore, textSize: Int) {
    val context = androidx.compose.ui.platform.LocalContext.current
    val lifecycle = LocalLifecycleOwner.current
    var elapsed by remember(row) { mutableLongStateOf(FocusStore.elapsed(row, context)) }
    LaunchedEffect(row.id, row.revision) {
        lifecycle.lifecycle.repeatOnLifecycle(Lifecycle.State.STARTED) {
            while (row.status == "running") {
                elapsed = FocusStore.elapsed(row, context)
                if (elapsed >= row.targetMs) {
                    try { store.refresh(); break }
                    catch(cancelled:CancellationException) { throw cancelled }
                    catch(_:Exception) { delay(2000);continue }
                }
                delay(1000)
            }
        }
    }
    val value = if (row.mode == "stopwatch" || row.status == "finished") elapsed else (row.targetMs - elapsed).coerceAtLeast(0)
    BoxWithConstraints(Modifier.fillMaxWidth().padding(vertical = 22.dp), contentAlignment = Alignment.Center) {
        val fontScale = androidx.compose.ui.platform.LocalDensity.current.fontScale
        val text = formatFocusDuration(value)
        val fitted = minOf(textSize.toFloat(), maxWidth.value / (text.length * .66f * fontScale))
        Text(text, fontSize = fitted.sp, fontFamily = FontFamily.Monospace, fontWeight = FontWeight.Light, maxLines = 1, color = Color.White)
    }
}
