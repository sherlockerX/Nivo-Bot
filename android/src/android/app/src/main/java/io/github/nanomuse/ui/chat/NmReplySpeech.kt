package io.github.nanomuse.ui.chat

import android.content.Context
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.Stable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext
import com.openminis.app.speech.ReadAloudPlayer
import com.openminis.app.speech.VoiceOutputState
import com.openminis.app.ui.chat.ChatMessage
import com.openminis.app.ui.chat.ChatViewModel
import com.openminis.app.ui.chat.voice.VoiceModePrefs
import io.github.nanomuse.speech.CoachSpeechRouting
import io.github.nanomuse.speech.SpeechOutputPolicy
import io.github.nanomuse.speech.isCoachToolName
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.drop

/** 聊天页面仅在收到最终答复或手动点击时朗读，同一时刻只播放一条回复。 */
@Stable
class NmReplySpeech(context: Context) {
    /** 专题身份约束整段会话，普通教学和历史选区同样只使用系统语音。 */
    internal var systemOnlyConversation: Boolean = false
    private val appContext = context.applicationContext
    private val idle = MutableStateFlow(false)
    private var player by mutableStateOf<ReadAloudPlayer?>(null)
    // 每种路由各留一个播放器：教练回复和普通回复交替朗读时不必每次销毁重建、重新绑定语音引擎。
    private val players = mutableMapOf<SpeechOutputPolicy, ReadAloudPlayer>()
    private val routing = CoachSpeechRouting()

    /** 当前朗读的消息，供答复操作行显示停止按钮。 */
    var readingId by mutableStateOf<String?>(null)
        private set

    /** 当前是否有正在播放或排队的正文。 */
    val speaking: StateFlow<Boolean> get() = player?.isSpeaking ?: idle

    private fun obtain(policy: SpeechOutputPolicy): ReadAloudPlayer =
        // 切换来源时由 read() 停止原来的播放器并把当前实例登记到顶层，胶囊和音频输出始终由当前实例持有。
        players.getOrPut(policy) { ReadAloudPlayer(appContext, policy = policy) }.also { player = it }

    /** 记录教练答复的来源约束，即使当时关闭了自动朗读也适用于手动重读。 */
    internal fun rememberRouting(messageId: String, systemOnly: Boolean) {
        routing.remember(messageId, systemOnly)
    }

    /** 选中文字与整条答复共用消息路由，跨消息选区也保留教练约束。 */
    internal fun selectionPolicy(messageIds: List<String>, orderedMessageIds: List<String>): SpeechOutputPolicy =
        if (systemOnlyConversation) SpeechOutputPolicy.SYSTEM_ONLY
        else routing.policyForSelection(messageIds, orderedMessageIds)

    /** 从头朗读完整正文，教练答复始终使用系统语音。 */
    fun read(messageId: String, text: String, systemOnly: Boolean = false) {
        readingId = messageId
        // 新建的播放器在构造时就登记为当前播放器，所以要在 obtain 之前记下原来在播放的那个并停止它。
        val previous = VoiceOutputState.activePlayer
        val selected = obtain(routing.policyFor(messageId, systemOnly || systemOnlyConversation))
        previous?.takeIf { it !== selected }?.stop()
        VoiceOutputState.registerPlayer(selected)
        selected.readAloud(text)
    }

    /** 停止当前朗读并丢弃排队文本。 */
    fun stop() {
        readingId = null
        player?.stop()
    }

    /** 页面离开时释放当前播放器和路由索引。 */
    fun shutdown() {
        players.values.forEach { it.shutdown() }
        players.clear()
        player = null
        readingId = null
        routing.clear()
    }
}

/** 为页面延迟创建朗读控制器，并在页面销毁时释放语音资源。 */
@Composable
fun rememberNmReplySpeech(systemOnlyConversation: Boolean = false): NmReplySpeech {
    val context = LocalContext.current
    val speech = remember {
        VoiceOutputState.init(context)
        NmReplySpeech(context)
    }
    speech.systemOnlyConversation = systemOnlyConversation
    DisposableEffect(speech) { onDispose { speech.shutdown() } }
    return speech
}

/**
 * The answer in a reply: the words after its last step (a tool call), so "let me look that up"
 * before a search is not the answer; all of the words when there was no step. Thinking is
 * never part of it.
 */
internal fun answerText(blocks: List<com.openminis.app.ui.chat.AssistantBlock>, content: String): String {
    val lastStep = blocks.indexOfLast { it.kind == "tool_use" }
    if (lastStep < 0 && blocks.none { it.kind == "text" }) return content
    return blocks.drop(lastStep + 1).filter { it.kind == "text" && it.content.isNotEmpty() }.joinToString("\n\n") { it.content }
}

/** 普通聊天仅消费本轮的最终答复事件，工具、思考和失败的部分回复不会进入播放器。 */
@Composable
fun NmReadRepliesAloud(speech: NmReplySpeech, viewModel: ChatViewModel, messages: List<ChatMessage>,
    isVisible: Boolean = true, systemOnlyConversation: Boolean = false) {
    speech.systemOnlyConversation = systemOnlyConversation
    val currentSystemOnly by rememberUpdatedState(systemOnlyConversation)
    val enabled by VoiceOutputState.isEnabled.collectAsState()
    val muted by VoiceOutputState.isMuted.collectAsState()
    val editing by viewModel.editingMessageId.collectAsState()
    val active = isVisible && enabled && !muted && !(VoiceModePrefs.isVoiceActive && editing == null)
    val currentActive by rememberUpdatedState(active)
    DisposableEffect(viewModel, speech) {
        onDispose { speech.shutdown() }
    }
    LaunchedEffect(speech, active) {
        if (!active) speech.stop()
    }
    LaunchedEffect(viewModel, speech) {
        viewModel.inputText.drop(1).collect { speech.stop() }
    }
    LaunchedEffect(viewModel, speech) {
        viewModel.isStreaming.collect { isStreaming -> if (isStreaming) speech.stop() }
    }
    LaunchedEffect(speech, messages, systemOnlyConversation) {
        messages.filter { reply ->
            reply.role == "assistant" && (systemOnlyConversation || reply.toolBlocks.any { block ->
                block.kind == "tool_use" && isCoachToolName(block.toolName)
            })
        }.forEach { reply ->
            // 合并气泡和单条数据库消息共用策略，重新载入历史后仍使用系统语音。
            (reply.sourceDbIds + reply.id).forEach { messageId ->
                speech.rememberRouting(messageId, systemOnly = true)
            }
        }
    }
    LaunchedEffect(viewModel, speech) {
        viewModel.finalReplies.collect { answer ->
            speech.rememberRouting(answer.messageId, answer.systemOnly || currentSystemOnly)
            if (!currentActive) return@collect
            VoiceModePrefs.lastSpokenAssistantKey = answer.messageId.hashCode()
            speech.read(answer.messageId, answer.text, systemOnly = answer.systemOnly || currentSystemOnly)
        }
    }
}
