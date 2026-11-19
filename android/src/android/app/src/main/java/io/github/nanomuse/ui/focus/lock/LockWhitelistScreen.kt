package io.github.nanomuse.ui.focus.lock

import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.openminis.app.R
import io.github.nanomuse.focus.lock.*
import io.github.nanomuse.ui.focus.FocusPanel
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.launch

/** 白名单使用持久集合，图标仅在可见行加载。 */
@Composable
fun LockWhitelistScreen(store:LockStore,bottomInset:androidx.compose.ui.unit.Dp=0.dp) {
    val context=LocalContext.current
    val scope=rememberCoroutineScope()
    var apps by remember(store) { mutableStateOf<List<InstalledApp>>(emptyList()) }
    var query by remember { mutableStateOf("") }
    var showSystem by remember { mutableStateOf(false) }
    var busy by remember { mutableStateOf(false) }
    var failed by remember { mutableStateOf(false) }
    var loaded by remember { mutableStateOf(false) }
    val selected by remember(store) { store.observeWhitelist().catch { if(it is CancellationException) throw it; failed=true } }.collectAsState(emptySet())
    val runs by remember(store) { store.observeRuns().catch { if(it is CancellationException) throw it; failed=true } }.collectAsState(emptyList())
    val isLocked=runs.any { it.status==LockRunStatus.ACTIVE }
    LaunchedEffect(store) {
        try { apps=InstalledApps.load(context);loaded=true }
        catch(cancelled:CancellationException) { throw cancelled }
        catch(_:Exception) { failed=true }
    }
    fun choose(packageName:String,value:Boolean) {
        if(busy) return
        busy=true
        scope.launch { try {
            // 强制期间Nivo只开放锁页；旧版本存进白名单的Nivo自身在下次修改时一并去掉。
            store.setWhitelist((if(value) selected+packageName else selected-packageName)-context.packageName);failed=false
        } catch(cancelled:CancellationException) { throw cancelled }
        catch(_:Exception) { failed=true }
        finally { busy=false } }
    }
    val visible=remember(apps,selected,query,showSystem) { apps.filter {
        it.packageName!=context.packageName && (showSystem || !it.isSystem || it.packageName in selected) &&
            (it.label.contains(query,true) || it.packageName.contains(query,true))
    }.sortedWith(compareByDescending<InstalledApp>{it.packageName in selected}.thenBy{it.label.lowercase()}) }
    LazyColumn(contentPadding=PaddingValues(20.dp,16.dp,20.dp,bottomInset+24.dp),verticalArrangement=Arrangement.spacedBy(12.dp)) {
        item { Text(stringResource(R.string.nm_lock_whitelist_hint));Spacer(Modifier.height(12.dp))
            OutlinedTextField(query,{query=it},label={Text(stringResource(R.string.nm_lock_search))},modifier=Modifier.fillMaxWidth(),singleLine=true)
            Row(verticalAlignment=Alignment.CenterVertically) { Checkbox(showSystem,{showSystem=it});Text(stringResource(R.string.nm_lock_system_apps)) }
        }
        if(!loaded && !failed) item { LinearProgressIndicator(Modifier.fillMaxWidth()) }
        if(failed) item { Text(stringResource(R.string.nm_lock_error),color=MaterialTheme.colorScheme.error) }
        if(loaded && visible.isEmpty()) item { Text(stringResource(R.string.nm_lock_empty_apps)) }
        items(visible,key={it.packageName}) { app -> FocusPanel {
            Row(verticalAlignment=Alignment.CenterVertically,horizontalArrangement=Arrangement.spacedBy(12.dp)) {
                val icon by produceState<android.graphics.Bitmap?>(null,app.packageName) { value=InstalledApps.loadIcon(context,app.packageName) }
                icon?.let { Image(it.asImageBitmap(),null,Modifier.size(38.dp)) }
                Column(Modifier.weight(1f)) {
                    Text(app.label,style=MaterialTheme.typography.titleSmall)
                    Text(app.packageName,style=MaterialTheme.typography.bodySmall)
                    if(app.isForbidden) Text(stringResource(R.string.nm_lock_never_allowed),style=MaterialTheme.typography.bodySmall)
                    else if(app.isAlwaysAllowed) Text(stringResource(R.string.nm_lock_always_allowed),style=MaterialTheme.typography.bodySmall)
                    if(!app.isLaunchable) Text(stringResource(R.string.nm_lock_no_launcher),style=MaterialTheme.typography.bodySmall)
                }
                Checkbox(app.packageName in selected,{choose(app.packageName,it)},enabled=!busy && !app.isForbidden && !app.isAlwaysAllowed && (!isLocked || app.packageName in selected))
            }
        } }
    }
}
