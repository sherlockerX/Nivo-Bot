package io.github.nanomuse.ui.focus.lock

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.repeatOnLifecycle
import com.openminis.app.R
import io.github.nanomuse.focus.lock.*
import io.github.nanomuse.ui.focus.formatFocusDuration
import kotlinx.coroutines.*

/** 长按后展示持久等待，最终确认由存储层再次核对，隐藏页面不会缩短等待。 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
internal fun LockEmergencyContent(store: LockStore, run: LockRun, dial: () -> Unit) {
    val context = LocalContext.current
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    val emergency = remember(store) { LockEmergency(context, store) }
    val scope = rememberCoroutineScope()
    var isEnabled by remember(store) { mutableStateOf(false) }
    var wait by remember(run.id) { mutableStateOf<LockEmergencyWait?>(null) }
    var isBusy by remember { mutableStateOf(false) }
    var hasFailed by remember { mutableStateOf(false) }
    var isConfirming by remember(run.id) { mutableStateOf(false) }
    LaunchedEffect(store, run.id) {
        isEnabled = withContext(Dispatchers.IO) { LockSettings(context, store).emergencyEnabled() }
        if (!isEnabled) return@LaunchedEffect
        lifecycle.repeatOnLifecycle(Lifecycle.State.STARTED) {
            while (isActive) {
                try { wait = emergency.state(run.id) }
                catch (cancelled: CancellationException) { throw cancelled }
                catch (_: Exception) { hasFailed = true }
                delay(500)
            }
        }
    }
    if (!isEnabled) return
    val beginLabel = stringResource(R.string.nm_lock_emergency_hold)
    fun begin() {
        if (isBusy) return
        isBusy = true; hasFailed = false
        scope.launch {
            try { wait = emergency.begin(run.id) }
            catch (cancelled: CancellationException) { throw cancelled }
            catch (_: Exception) { hasFailed = true }
            finally { isBusy = false }
        }
    }
    Column(Modifier.fillMaxWidth().widthIn(max = 480.dp).padding(top = 22.dp),
        horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(10.dp)) {
        val current = wait
        if (current == null) {
            Surface(color = Color.White.copy(alpha = .12f), contentColor = Color.White,
                shape = RoundedCornerShape(20.dp), modifier = Modifier.combinedClickable(
                    enabled = !isBusy, onClick = {}, onLongClickLabel = beginLabel, onLongClick = ::begin)) {
                Text(beginLabel, Modifier.padding(horizontal = 20.dp, vertical = 16.dp))
            }
            Text(stringResource(R.string.nm_lock_emergency_hint), color = Color.White.copy(alpha = .85f),
                style = MaterialTheme.typography.bodySmall)
        } else if (current.remainingMs > 0) {
            Text(stringResource(R.string.nm_lock_emergency_waiting, formatFocusDuration(current.remainingMs)), color = Color.White)
            Text(stringResource(R.string.nm_lock_emergency_wait_hint), color = Color.White.copy(alpha = .85f),
                style = MaterialTheme.typography.bodySmall)
        } else {
            FilledTonalButton(enabled = !isBusy, onClick = { isConfirming = true }) {
                Text(stringResource(R.string.nm_lock_emergency_confirm))
            }
        }
        if (isBusy) LinearProgressIndicator(Modifier.fillMaxWidth())
        if (hasFailed) Text(stringResource(R.string.nm_lock_error), color = Color.White)
    }
    if (isConfirming) AlertDialog(onDismissRequest = { if (!isBusy) isConfirming = false },
        title = { Text(stringResource(R.string.nm_lock_emergency_confirm)) },
        text = { Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text(stringResource(R.string.nm_lock_emergency_confirm_hint))
            TextButton(onClick = { isConfirming = false; dial() }) { Text(stringResource(R.string.nm_lock_dial)) }
        } },
        confirmButton = { TextButton(enabled = !isBusy, onClick = {
            isBusy = true; hasFailed = false
            scope.launch {
                try { emergency.confirm(run.id); isConfirming = false }
                catch (cancelled: CancellationException) { throw cancelled }
                catch (_: Exception) { hasFailed = true; isConfirming = false }
                finally { isBusy = false }
            }
        }) { Text(stringResource(R.string.nm_lock_emergency_confirm)) } },
        dismissButton = { TextButton(enabled = !isBusy, onClick = { isConfirming = false }) {
            Text(stringResource(R.string.nm_lock_emergency_keep))
        } })
}
