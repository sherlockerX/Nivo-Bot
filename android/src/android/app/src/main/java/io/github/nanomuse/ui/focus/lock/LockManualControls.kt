package io.github.nanomuse.ui.focus.lock

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.repeatOnLifecycle
import com.openminis.app.R
import io.github.nanomuse.focus.lock.LockPermissions
import io.github.nanomuse.ui.focus.FocusUi
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext

/** 从权限页返回时重新检查真实连接，未就绪的开关始终不可选。 */
@Composable
fun LockManualControls(isSelected: Boolean, isFixedDuration: Boolean, onSelected: (Boolean) -> Unit) {
    val context = LocalContext.current
    val lifecycle = LocalLifecycleOwner.current
    var isReady by remember { mutableStateOf(false) }
    LaunchedEffect(lifecycle) {
        lifecycle.lifecycle.repeatOnLifecycle(Lifecycle.State.STARTED) {
            while (true) {
                isReady = withContext(Dispatchers.IO) { LockPermissions.read(context).isReady }
                if (!isReady || !isFixedDuration) onSelected(false)
                delay(1500)
            }
        }
    }
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text(stringResource(R.string.nm_lock_this_session), Modifier.weight(1f))
        Switch(checked = isSelected && isFixedDuration, enabled = isReady && isFixedDuration,
            onCheckedChange = onSelected)
    }
    if (isSelected) Text(stringResource(R.string.nm_lock_start_hint), style = MaterialTheme.typography.bodySmall)
    Row {
        TextButton(onClick = { FocusUi.view.value = "lock-whitelist" }) { Text(stringResource(R.string.nm_lock_whitelist)) }
        if (!isReady) TextButton(onClick = { FocusUi.view.value = "lock-permissions" }) { Text(stringResource(R.string.nm_lock_permissions)) }
    }
}
