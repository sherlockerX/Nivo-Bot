package io.github.nanomuse.ui.chat

import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.repeatOnLifecycle
import com.openminis.app.service.SessionActivityTracker

/** 只有真正显示并已恢复的聊天算已读，隐藏页和后台不会消费完成状态。 */
@Composable
fun ConversationReadEffect(sessionId: String, visible: Boolean) {
    val owner = LocalLifecycleOwner.current
    val context = androidx.compose.ui.platform.LocalContext.current
    androidx.compose.runtime.LaunchedEffect(sessionId, visible) {
        if (!visible) return@LaunchedEffect
        owner.lifecycle.repeatOnLifecycle(Lifecycle.State.RESUMED) {
            val warning = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
                io.github.nanomuse.routines.ScheduledFailureNotice.pending(context)
            }
            if (warning.isNotBlank()) android.widget.Toast.makeText(context, context.getString(com.openminis.app.R.string.nm_schedule_warning, warning), android.widget.Toast.LENGTH_LONG).show()
            kotlinx.coroutines.awaitCancellation()
        }
    }
    DisposableEffect(sessionId, visible, owner) {
        fun refresh() = SessionActivityTracker.conversationRuns.setViewing(sessionId,
            visible && owner.lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED))
        val observer = LifecycleEventObserver { _, _ -> refresh() }
        owner.lifecycle.addObserver(observer)
        refresh()
        onDispose {
            owner.lifecycle.removeObserver(observer)
            SessionActivityTracker.conversationRuns.setViewing(sessionId, false)
        }
    }
}
