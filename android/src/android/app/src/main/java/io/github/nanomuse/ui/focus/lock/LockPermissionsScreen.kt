package io.github.nanomuse.ui.focus.lock

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.repeatOnLifecycle
import com.openminis.app.R
import io.github.nanomuse.focus.lock.LockPermissions
import io.github.nanomuse.ui.focus.FocusPanel
import kotlinx.coroutines.delay

/** 回到前台自动刷新授权，显示真实服务连接与系统开关之间的区别。 */
@Composable
fun LockPermissionsScreen(bottomInset: androidx.compose.ui.unit.Dp = 0.dp) {
    val context = LocalContext.current
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    var state by remember { mutableStateOf(LockPermissions.read(context)) }
    var failed by remember { mutableStateOf(false) }
    LaunchedEffect(lifecycle) { lifecycle.repeatOnLifecycle(Lifecycle.State.RESUMED) {
        while (true) { state = LockPermissions.read(context); delay(1500) }
    } }
    LazyColumn(contentPadding=PaddingValues(20.dp,16.dp,20.dp,bottomInset+24.dp),verticalArrangement=Arrangement.spacedBy(14.dp)) {
        item { FocusPanel {
            Text(stringResource(if(state.isReady) R.string.nm_lock_ready else R.string.nm_lock_not_ready),style=MaterialTheme.typography.titleMedium)
            if(state.sdk<30) Text(stringResource(R.string.nm_lock_android_version))
            if(state.isAccessibilityStale) Text(stringResource(R.string.nm_lock_stale),color=MaterialTheme.colorScheme.error)
            Text(stringResource(R.string.nm_lock_privacy),style=MaterialTheme.typography.bodyMedium)
        } }
        item { PermissionRow(R.string.nm_lock_accessibility,state.isAccessibilityEnabled && state.isAccessibilityConnected) { failed=!LockPermissions.open(context,LockPermissions.Kind.ACCESSIBILITY) } }
        item { PermissionRow(R.string.nm_lock_overlay,state.hasOverlay) { failed=!LockPermissions.open(context,LockPermissions.Kind.OVERLAY) } }
        item { PermissionRow(R.string.nm_lock_usage,state.hasUsageAccess) { failed=!LockPermissions.open(context,LockPermissions.Kind.USAGE) } }
        item { PermissionRow(R.string.nm_lock_exact,state.hasExactAlarms) { failed=!LockPermissions.open(context,LockPermissions.Kind.EXACT_ALARM) } }
        item { PermissionRow(R.string.nm_lock_notifications,state.hasNotifications) { failed=!LockPermissions.open(context,LockPermissions.Kind.NOTIFICATIONS) } }
        item { PermissionRow(R.string.nm_lock_battery,state.isBatteryUnrestricted) { failed=!LockPermissions.open(context,LockPermissions.Kind.BATTERY) } }
        item { Text(stringResource(R.string.nm_lock_battery_hint)); Spacer(Modifier.height(12.dp));Text(stringResource(R.string.nm_lock_limitations)) }
        if(failed) item { Text(stringResource(R.string.nm_lock_error),color=MaterialTheme.colorScheme.error) }
    }
}

@Composable
private fun PermissionRow(label:Int,isReady:Boolean,onOpen:()->Unit) { FocusPanel {
    Text(stringResource(label),style=MaterialTheme.typography.titleMedium)
    Text(stringResource(if(isReady) R.string.nm_lock_granted else R.string.nm_lock_required))
    OutlinedButton(onClick=onOpen) { Text(stringResource(R.string.nm_lock_open_settings)) }
} }
