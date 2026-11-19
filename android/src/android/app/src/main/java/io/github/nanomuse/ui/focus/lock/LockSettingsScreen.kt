package io.github.nanomuse.ui.focus.lock

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.openminis.app.R
import io.github.nanomuse.focus.FocusStore
import io.github.nanomuse.focus.lock.LockBackup
import io.github.nanomuse.focus.lock.LockDiagnostics
import io.github.nanomuse.focus.lock.LockSettings
import io.github.nanomuse.focus.lock.LockStore
import io.github.nanomuse.ui.focus.FocusPanel
import io.github.nanomuse.ui.focus.FocusUi
import kotlinx.coroutines.*

/** 恢复只处理配置，文件选择回调保留原账号与代次。 */
@Composable
fun LockSettingsScreen(focus:FocusStore,bottomInset:androidx.compose.ui.unit.Dp=0.dp) {
    val context=LocalContext.current
    val scope=rememberCoroutineScope()
    var busy by remember { mutableStateOf(false) }
    var message by remember { mutableIntStateOf(0) }
    var captured by remember { mutableStateOf<Pair<String,Long>?>(null) }
    val lockStore=remember(focus) { LockStore.get(context) }
    val settings=remember(lockStore) { LockSettings(context,lockStore) }
    var isLoaded by remember(lockStore) { mutableStateOf(false) }
    var isEmergencyEnabled by remember(lockStore) { mutableStateOf(true) }
    var shouldShowOnWake by remember(lockStore) { mutableStateOf(true) }
    var shouldConfirmDisable by remember { mutableStateOf(false) }
    LaunchedEffect(lockStore) { withContext(Dispatchers.IO) {
        isEmergencyEnabled=settings.emergencyEnabled();shouldShowOnWake=settings.showOnWake()
    };isLoaded=true }
    fun save(emergency:Boolean,wake:Boolean) {
        if(busy) return
        busy=true
        scope.launch {
            try {
                settings.update(emergency,wake)
                isEmergencyEnabled=emergency;shouldShowOnWake=wake
                shouldConfirmDisable=false;message=R.string.nm_lock_settings_saved
            } catch(cancelled:CancellationException) { throw cancelled }
            catch(_:Exception) { message=R.string.nm_lock_error }
            finally { busy=false }
        }
    }
    val importer=rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if(uri!=null && captured==Pair(focus.ownerKey,focus.ownerEpoch)) scope.launch {
            busy=true
            try {
                withContext(Dispatchers.IO) {
                    val bytes=checkNotNull(context.contentResolver.openInputStream(uri)).use { source ->
                        val output=java.io.ByteArrayOutputStream()
                        val buffer=ByteArray(8192)
                        while(true) {
                            val count=source.read(buffer)
                            if(count<0) break
                            require(output.size()+count<=LockBackup.MAX_FOCUS_BACKUP_BYTES)
                            output.write(buffer,0,count)
                        }
                        output.toByteArray()
                    }
                    require(bytes.size<=LockBackup.MAX_FOCUS_BACKUP_BYTES)
                    focus.importLockConfiguration(bytes.toString(Charsets.UTF_8))
                }
                message=R.string.nm_lock_imported
            } catch(cancelled:CancellationException) { throw cancelled }
            catch(_:Exception) { message=R.string.nm_lock_error }
            finally { busy=false }
        }
    }
    LazyColumn(contentPadding=PaddingValues(20.dp,16.dp,20.dp,bottomInset+24.dp),verticalArrangement=Arrangement.spacedBy(14.dp)) {
        item { FocusPanel {
            TextButton(onClick={FocusUi.view.value="lock-permissions"}) { Text(stringResource(R.string.nm_lock_permissions)) }
            TextButton(onClick={FocusUi.view.value="lock-whitelist"}) { Text(stringResource(R.string.nm_lock_whitelist)) }
        } }
        item { FocusPanel {
            Row(verticalAlignment=androidx.compose.ui.Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text(stringResource(R.string.nm_lock_emergency_setting),style=MaterialTheme.typography.titleMedium)
                    Text(stringResource(R.string.nm_lock_emergency_setting_hint),style=MaterialTheme.typography.bodySmall)
                }
                Switch(checked=isEmergencyEnabled,enabled=isLoaded && !busy,onCheckedChange={next ->
                    if(next) save(true,shouldShowOnWake) else shouldConfirmDisable=true
                })
            }
            Row(verticalAlignment=androidx.compose.ui.Alignment.CenterVertically) {
                Text(stringResource(R.string.nm_lock_show_on_wake),Modifier.weight(1f))
                Switch(checked=shouldShowOnWake,enabled=isLoaded && !busy,onCheckedChange={ save(isEmergencyEnabled,it) })
            }
            Text(stringResource(R.string.nm_lock_show_on_wake_hint),style=MaterialTheme.typography.bodySmall)
        } }
        item { FocusPanel {
            Text(stringResource(R.string.nm_lock_import_hint))
            OutlinedButton(enabled=!busy,onClick={ captured=Pair(focus.ownerKey,focus.ownerEpoch); importer.launch(arrayOf("application/json","text/plain")) }) { Text(stringResource(R.string.nm_lock_import)) }
            if(busy) LinearProgressIndicator(Modifier.fillMaxWidth())
            if(message!=0) Text(stringResource(message))
        } }
        item { FocusPanel {
            Text(stringResource(R.string.nm_lock_diagnostics),style=MaterialTheme.typography.titleMedium)
            Text(stringResource(R.string.nm_lock_diagnostics_hint),style=MaterialTheme.typography.bodySmall)
            TextButton(enabled=!busy,onClick={busy=true;scope.launch {
                try {
                    val text=LockDiagnostics.exportText(context)
                    context.getSystemService(android.content.ClipboardManager::class.java).setPrimaryClip(
                        android.content.ClipData.newPlainText(context.getString(R.string.nm_lock_diagnostics),text))
                    message=R.string.nm_lock_diagnostics_copied
                } catch(cancelled:CancellationException) { throw cancelled }
                catch(_:Exception) { message=R.string.nm_lock_error }
                finally { busy=false }
            }}) { Text(stringResource(R.string.nm_lock_diagnostics_copy)) }
            TextButton(enabled=!busy,onClick={busy=true;scope.launch {
                try { LockDiagnostics.clear(context);message=R.string.nm_lock_diagnostics_cleared }
                catch(cancelled:CancellationException) { throw cancelled }
                catch(_:Exception) { message=R.string.nm_lock_error }
                finally { busy=false }
            }}) { Text(stringResource(R.string.nm_lock_diagnostics_clear)) }
        } }
        item { Text(stringResource(R.string.nm_lock_limitations)) }
    }
    if(shouldConfirmDisable) AlertDialog(onDismissRequest={if(!busy) shouldConfirmDisable=false},
        title={Text(stringResource(R.string.nm_lock_disable_emergency))},
        text={Text(stringResource(R.string.nm_lock_disable_emergency_hint))},
        confirmButton={TextButton(enabled=!busy,onClick={save(false,shouldShowOnWake)}) { Text(stringResource(R.string.nm_lock_disable_emergency)) }},
        dismissButton={TextButton(enabled=!busy,onClick={shouldConfirmDisable=false}) { Text(stringResource(android.R.string.cancel)) }})
}
