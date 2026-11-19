package io.github.nanomuse.ui.focus.lock

import android.content.Context
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.navigation.NavHostController
import androidx.navigation.compose.currentBackStackEntryAsState
import com.openminis.app.R
import io.github.nanomuse.focus.lock.*
import io.github.nanomuse.ui.focus.FocusImmersiveActivity
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * 强制期间主窗口的任何页面都不可用，包括聊天：遮住当前页面并转回锁页。
 * 导航图保持挂载，强制结束后从原来的页面继续。
 */
@Composable
fun LockNavigationGuard(nav: NavHostController) {
    val context = LocalContext.current
    val snapshot by LockRuntime.state.collectAsState()
    val entry by nav.currentBackStackEntryAsState()
    val route = entry?.destination?.route
    val current = snapshot
    val blocked = current != null && LockRuntime.remaining(context, current) > 0
    LaunchedEffect(blocked, current?.run?.id, route) {
        if (blocked && route != null) returnToLock(context)
    }
    if (blocked) Dialog(onDismissRequest = {}, properties = DialogProperties(
        dismissOnBackPress = false, dismissOnClickOutside = false,
        usePlatformDefaultWidth = false, decorFitsSystemWindows = false
    )) { LockRoutingPlaceholder() }
}

/** 强制期间不组合首页的标签和抽屉，避免在锁页之下继续绘制和计时。 */
@Composable
fun LockHomeGuard(): Boolean {
    val context = LocalContext.current
    val snapshot by LockRuntime.state.collectAsState()
    val current = snapshot
    val blocked = current != null && LockRuntime.remaining(context, current) > 0
    LaunchedEffect(blocked, current?.run?.id) { if (blocked) returnToLock(context) }
    if (blocked) LockRoutingPlaceholder()
    return !blocked
}

/** 重新结算后才打开锁页，已经到期的运行不能重新遮挡主窗口。 */
private suspend fun returnToLock(context: Context) {
    LockController.evaluate(context)?.let { FocusImmersiveActivity.open(context, it.ownerKey, it.sessionId) }
}

@Composable
private fun LockRoutingPlaceholder() {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    BackHandler { }
    Surface(Modifier.fillMaxSize()) {
        Column(Modifier.fillMaxSize().safeDrawingPadding().padding(24.dp),
            horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
            Text(stringResource(R.string.nm_lock_title), style = MaterialTheme.typography.titleLarge)
            TextButton(onClick = { scope.launch { returnToLock(context) } }) {
                Text(stringResource(R.string.nm_lock_return))
            }
            OutlinedButton(onClick = { scope.launch { withContext(Dispatchers.IO) { InstalledApps.openDialer(context) } } }) {
                Text(stringResource(R.string.nm_lock_dial))
            }
        }
    }
}
