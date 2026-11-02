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
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

/**
 * Mosaic: replies read aloud in a chat. One player per chat screen, bound the first time
 * something is spoken. It follows the reply being written while "Read replies aloud" is on
 * (the ⋯ menu), and reads a finished reply when its action row asks.
 */
@Stable
class NmReplySpeech(context: Context) {
    private val appContext = context.applicationContext
    private val idle = MutableStateFlow(false)
    private var player by mutableStateOf<ReadAloudPlayer?>(null)

    /** The reply being read, for its row's stop button; null when none is. */
    var readingId by mutableStateOf<String?>(null)
        private set

    /** Whether anything is playing or queued. */
    val speaking: StateFlow<Boolean> get() = player?.isSpeaking ?: idle

    internal fun obtain(): ReadAloudPlayer = player ?: ReadAloudPlayer(appContext).also { player = it }

    /** Reads a finished reply from its start, stopping whatever was being read. */
    fun read(messageId: String, text: String) {
        readingId = messageId
        obtain().readAloud(text)
    }

    fun stop() {
        readingId = null
        player?.stop()
    }

    internal fun follow(messageId: String) {
        readingId = messageId
    }

    fun shutdown() {
        player?.shutdown()
        player = null
        readingId = null
    }
}

@Composable
fun rememberNmReplySpeech(): NmReplySpeech {
    val context = LocalContext.current
    val speech = remember {
        VoiceOutputState.init(context)
        NmReplySpeech(context)
    }
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
fun NmReadRepliesAloud(speech: NmReplySpeech, viewModel: ChatViewModel, messages: List<ChatMessage>) {
    val enabled by VoiceOutputState.isEnabled.collectAsState()
    val muted by VoiceOutputState.isMuted.collectAsState()
    val editing by viewModel.editingMessageId.collectAsState()
    val active = enabled && !muted && !(VoiceModePrefs.isVoiceActive && editing == null)
    LaunchedEffect(viewModel, speech, active) {
        if (!active) { speech.stop(); return@LaunchedEffect }
        viewModel.finalReplies.collect { answer ->
            VoiceModePrefs.lastSpokenAssistantKey = answer.messageId.hashCode()
            speech.read(answer.messageId, answer.text)
        }
    }
}
