package io.github.nanomuse.ui.coach

import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.State
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext
import io.github.nanomuse.coach.CoachCommandService
import io.github.nanomuse.coach.CoachRuntime
import io.github.nanomuse.coach.CoachState
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.withContext

/** 账户代次变化时立即脱离旧服务，专题与课次变更均由同一状态流触发重组。 */
@Composable
internal fun rememberCoachConversationState(): State<CoachState> {
    val context = LocalContext.current.applicationContext
    val epoch by CoachRuntime.epoch.collectAsState()
    var service by remember(context, epoch) { mutableStateOf<CoachCommandService?>(null) }
    val empty = remember(context, epoch) { MutableStateFlow(CoachState()) }
    LaunchedEffect(context, epoch) {
        service = withContext(Dispatchers.IO) { runCatching { CoachRuntime.service(context) }.getOrNull() }
    }
    return (service?.state ?: empty).collectAsState()
}

/** 练习身份随权威绑定实时刷新，不依赖消息新增或偶然的界面重组。 */
@Composable
fun rememberCoachPracticeConversation(chatSessionId: String): Boolean {
    val state = rememberCoachConversationState()
    // 只在结果真的变化时重组调用方：聊天页顶层调用这里，每次档案写入都整页重组会拖慢流式显示。
    val isPractice by remember(state, chatSessionId) { derivedStateOf {
        state.value.topics.any { it.chatSessionId == chatSessionId && it.status == "active" && chatSessionId.isNotBlank() }
    } }
    return isPractice
}
