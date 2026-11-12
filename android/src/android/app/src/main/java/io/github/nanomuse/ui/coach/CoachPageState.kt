package io.github.nanomuse.ui.coach

import androidx.compose.runtime.*
import androidx.compose.ui.platform.LocalContext
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.openminis.app.speech.ReadAloudPlayer
import com.openminis.app.speech.VoiceOutputState
import io.github.nanomuse.coach.CoachAnswerDraftPolicy
import io.github.nanomuse.coach.CoachRuntime
import io.github.nanomuse.coach.CoachState
import io.github.nanomuse.speech.SpeechOutputPolicy
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import java.util.concurrent.atomic.AtomicBoolean

/** 输入先保留本地草稿，短暂防抖同步领域状态，离开时立即刷盘。 */
@Composable
internal fun rememberCoachInput(key: String, initial: String = ""): MutableState<String> {
    val context = LocalContext.current.applicationContext
    val runtimeEpoch by CoachRuntime.epoch.collectAsState()
    // 账户只在切换时变化（同时推进 epoch），不必每输入一个字都重新读取账户密钥。
    val account = remember(context, runtimeEpoch) { io.github.nanomuse.account.AccountData.key(context) }
    val prefs = remember(context, account) { context.getSharedPreferences("coach-inputs-v2-${account.hashCode()}", 0) }
    val answerId = key.takeIf { it.startsWith("answer:") }?.removePrefix("answer:")
    val service = remember(context, account, answerId, runtimeEpoch) {
        if (answerId != null) runCatching { CoachRuntime.service(context) }.getOrNull() else null
    }
    val empty = remember { kotlinx.coroutines.flow.MutableStateFlow(CoachState()) }
    val state by (service?.state ?: empty).collectAsState()
    val answerSession = state.sessions.find { it.id == answerId }
    val target = answerSession?.let(CoachAnswerDraftPolicy::target)
    // 题目或提交回合变化才重建输入状态，普通自动保存不会打断光标或清除新输入。
    val value = remember(key, account, target) { mutableStateOf(
        if (answerId != null) answerSession?.draft ?: initial else prefs.getString(key, null) ?: initial) }
    val isEditorActive = remember(key, account, target) { AtomicBoolean(true) }
    val owner = LocalLifecycleOwner.current
    fun flush(text: String) {
        if (answerId == null) {
            // 离开页面和 ON_STOP 在主线程调用这里；每次改动都已排队写入，apply 不会在主线程等磁盘。
            prefs.edit().putString(key, text).apply()
            return
        }
        val currentService = service ?: return
        val editorTarget = target ?: return
        CoachAnswerDraftPolicy.save(currentService, editorTarget, text) {
            isEditorActive.get() && value.value == text &&
                account == io.github.nanomuse.account.AccountData.key(context)
        }
    }
    LaunchedEffect(key, account, target, value.value) {
        val text = value.value
        if (answerId == null) prefs.edit().putString(key, text).apply()
        delay(350)
        withContext(Dispatchers.IO) { flush(text) }
    }
    DisposableEffect(key, account, target, owner) {
        isEditorActive.set(true)
        val observer = LifecycleEventObserver { _, event -> if (event == Lifecycle.Event.ON_STOP) flush(value.value) }
        owner.lifecycle.addObserver(observer)
        onDispose {
            owner.lifecycle.removeObserver(observer)
            flush(value.value)
            isEditorActive.set(false)
        }
    }
    return value
}

/** 档案页只响应手动重读，正文自动朗读由当前专题聊天负责。 */
@Composable
internal fun CoachPageSpeech() {
    val context = LocalContext.current
    // 第一次重读时才创建播放器：打开档案页不绑定语音引擎，也不抢走聊天朗读胶囊的控制。
    val holder = remember { java.util.concurrent.atomic.AtomicReference<ReadAloudPlayer?>(null) }
    val view by CoachUi.view.collectAsState()
    val enabled by VoiceOutputState.isEnabled.collectAsState()
    val muted by VoiceOutputState.isMuted.collectAsState()
    LaunchedEffect(view, enabled, muted) { holder.get()?.stop() }
    DisposableEffect(holder) {
        CoachUi.readReply = { text ->
            // 新播放器构造时就登记为当前播放器，先记下原来在播放的那个再停止它。
            val previous = VoiceOutputState.activePlayer
            val player = holder.get() ?: ReadAloudPlayer(context, policy = SpeechOutputPolicy.SYSTEM_ONLY).also { holder.set(it) }
            previous?.takeIf { it !== player }?.stop()
            VoiceOutputState.registerPlayer(player)
            player.readAloud(text)
        }
        onDispose { CoachUi.readReply = null; holder.getAndSet(null)?.shutdown() }
    }
}
