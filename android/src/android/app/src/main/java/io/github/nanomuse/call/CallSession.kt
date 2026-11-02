package io.github.nanomuse.call

import android.content.Context
import android.util.Log
import com.openminis.app.R
import com.openminis.app.data.model.ThinkingLevel
import com.openminis.app.speech.VoiceTextSanitizer
import com.openminis.app.ui.chat.AssistantBlock
import com.openminis.app.ui.chat.ChatViewModel
import io.github.nanomuse.chat.SessionAddenda
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull

/** Where a call is: waiting to be connected, listening, hearing the person, working on a reply, saying it, or over. */
enum class CallPhase { CONNECTING, LISTENING, HEARING, THINKING, SPEAKING, ENDED }

/**
 * One voice call with the agent, turn by turn. The person speaks, Fun-ASR transcribes it as they
 * go and ends the turn after a pause; the text goes into the chat as an ordinary message, so the
 * reply comes from the same model, persona and memory and the call stays in the conversation; the
 * reply streams into CosyVoice as it is written and plays as it arrives.
 *
 * Mosaic: the person can cut in. Recognition stays open while the agent works and speaks; when
 * they speak over it (two or more letters or characters that are not mostly the words being said,
 * which would be the agent's own voice coming back), or tap Interrupt, the reply stops being
 * written and said, and what they say becomes the next turn.
 *
 * For the call the session's thinking is switched off and a short system addendum asks for
 * spoken, short replies; both are put back when the call ends.
 */
class CallSession(
    private val context: Context,
    private val vm: ChatViewModel,
    private val routeSessionId: String,
    private val apiKey: String,
    private val settings: CallSettings,
) {
    private val _phase = MutableStateFlow(CallPhase.CONNECTING)
    val phase: StateFlow<CallPhase> = _phase.asStateFlow()

    /** What the person is saying, or said last. */
    val heard = MutableStateFlow("")

    /** What the agent is saying. */
    val reply = MutableStateFlow("")
    val problem = MutableStateFlow<String?>(null)
    val muted = MutableStateFlow(false)
    val speaker = MutableStateFlow(false)

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val audio = CallAudio(context)
    @Volatile private var recognizer: StreamingRecognizer? = null
    @Volatile private var synthesizer: StreamingSynthesizer? = null
    /** Mosaic: completed to cut the reply in progress short. */
    @Volatile private var cutIn: CompletableDeferred<Unit>? = null
    private var thinkingBefore: ThinkingLevel? = null
    @Volatile private var released = false

    private val sessionKey: String get() = vm.realSessionId.ifEmpty { routeSessionId }

    fun start() {
        thinkingBefore = vm.thinkingLevel.value
        if (vm.thinkingLevel.value.isEnabled) vm.setThinkingLevel(ThinkingLevel.OFF)
        SessionAddenda.add(sessionKey, ADDENDUM_TAG, CALL_PROMPT, turns = Int.MAX_VALUE)
        audio.startRouting(speaker.value)
        scope.launch(Dispatchers.IO) { listenToMic() }
        scope.launch { converse() }
    }

    fun setMuted(on: Boolean) {
        muted.value = on
    }

    fun setSpeaker(on: Boolean) {
        speaker.value = on
        audio.setSpeaker(on)
    }

    /** Mosaic: the Interrupt button: stops the reply now and listens. */
    fun interrupt() {
        cutIn?.complete(Unit)
    }

    /** Ends the call and puts the session back as it was. Safe to call more than once. */
    fun hangUp() {
        synchronized(this) {
            if (released) return
            released = true
        }
        _phase.value = CallPhase.ENDED
        scope.cancel()
        recognizer?.cancel()
        synthesizer?.cancel()
        if (vm.isStreaming.value) vm.cancelStream()
        audio.release()
        SessionAddenda.remove(sessionKey, ADDENDUM_TAG)
        SessionAddenda.remove(routeSessionId, ADDENDUM_TAG)
        thinkingBefore?.takeIf { it.isEnabled }?.let { vm.setThinkingLevel(it) }
    }

    private fun listenToMic() {
        if (!audio.openMic()) {
            if (!released) fail(context.getString(R.string.nm_call_error_mic))
            return
        }
        val frame = ByteArray(CallAudio.MIC_FRAME_BYTES)
        while (scope.isActive) {
            val n = audio.readMic(frame)
            if (n < 0) return
            if (n == 0) continue
            // Mosaic: open in every phase, so the person can speak over the reply.
            // Muted, the recogniser gets silence: with nothing at all it ends the task after 23 s.
            recognizer?.send(if (muted.value) ByteArray(n) else frame.copyOf(n))
        }
    }

    private suspend fun converse() {
        var ear = Ear()
        while (scope.isActive) {
            val said = listen(ear) ?: break
            // Mosaic: the next turn is heard from the moment the reply starts, so speaking over it cuts in.
            ear = Ear()
            recognizer = ear.asr
            answer(said)
        }
        // Recognition failed: let go of the microphone, the call routing and the session now and
        // leave the reason on the page; hanging up from the page afterwards changes nothing.
        withContext(Dispatchers.Main) { hangUp() }
    }

    /**
     * Mosaic: one recognition task and the first sentence it accepts (null when recognition
     * failed). It starts when the agent starts answering: while the agent works or speaks, only
     * speech that [cutsIn] counts, and the first such words cut the reply short; afterwards every
     * sentence counts.
     */
    private inner class Ear {
        val sentence = CompletableDeferred<String?>()
        @Volatile var partial = ""
        @Volatile private var spokeOver = false
        val asr = StreamingRecognizer(settings, apiKey, CallAudio.MIC_RATE, object : StreamingRecognizer.Events {
            override fun onPartial(text: String) = onHeard(text, end = false)
            override fun onSentence(text: String) = onHeard(text, end = true)
            override fun onFailure(failure: StreamFailure) {
                if (sentence.isCompleted) return
                problem.value = describe(failure)
                sentence.complete(null)
            }
        })

        private fun onHeard(text: String, end: Boolean) {
            if (text.isEmpty() || sentence.isCompleted) return
            val replying = _phase.value == CallPhase.THINKING || _phase.value == CallPhase.SPEAKING
            if (replying && !spokeOver) {
                if (!cutsIn(text, reply.value)) return
                spokeOver = true
                cutIn?.complete(Unit)
            }
            partial = text
            heard.value = text
            if (_phase.value == CallPhase.LISTENING) _phase.value = CallPhase.HEARING
            if (end) sentence.complete(text)
        }
    }

    /** One turn of the person: the first finished sentence [ear] accepts, or null when recognition failed. */
    private suspend fun listen(ear: Ear): String? {
        recognizer = ear.asr
        heard.value = ear.partial
        _phase.value = if (ear.partial.isEmpty()) CallPhase.LISTENING else CallPhase.HEARING
        val said = ear.sentence.await()
        if (said == null) {
            recognizer = null
            ear.asr.cancel()
            _phase.value = CallPhase.ENDED
        } else {
            ear.asr.finish()
        }
        return said
    }

    /**
     * One turn of the agent: the message into the chat, the reply streamed into speech. Mosaic:
     * cut short when the person speaks over it or taps Interrupt: the speech stops at once, the
     * reply stops being written, and the call listens.
     */
    private suspend fun answer(said: String) {
        heard.value = said
        reply.value = ""
        problem.value = null
        _phase.value = CallPhase.THINKING
        val cut = CompletableDeferred<Unit>()
        cutIn = cut
        val spoken = CompletableDeferred<Unit>()
        // Speech is written on its own thread: AudioTrack.write blocks while its buffer is full, and
        // blocking the socket's reader thread would hold back the pongs and drop a long reply.
        val playback = Channel<ByteArray>(Channel.UNLIMITED)
        val player = scope.launch(Dispatchers.IO) { for (pcm in playback) audio.play(pcm) }
        val tts = StreamingSynthesizer(settings, apiKey, CallAudio.SPEECH_RATE, object : StreamingSynthesizer.Events {
            override fun onAudio(pcm: ByteArray) {
                if (_phase.value == CallPhase.THINKING) _phase.value = CallPhase.SPEAKING
                playback.trySend(pcm)
            }

            override fun onDone() {
                spoken.complete(Unit)
            }

            override fun onFailure(failure: StreamFailure) {
                problem.value = describe(failure)
                spoken.complete(Unit)
            }
        })
        synthesizer = tts
        coroutineScope {
            val work = launch {
                val chunker = SpeechChunker(tts::push)
                val before = vm.uiMessages.value.map { it.id }.toSet()
                var written = 0
                withContext(Dispatchers.Main) { vm.sendMessage(said) }
                if (withTimeoutOrNull(START_TIMEOUT_MS) { vm.isStreaming.first { it } } != null) {
                    coroutineScope {
                        val follow = launch {
                            vm.streamingById.collect { streams ->
                                val text = streams.values.firstOrNull()?.let { spokenText(it.toolBlocks, it.content) } ?: return@collect
                                if (text.length > written) {
                                    chunker.add(text.substring(written))
                                    written = text.length
                                    reply.value = text
                                }
                            }
                        }
                        vm.isStreaming.first { !it }
                        follow.cancel()
                    }
                }
                // The tail: whatever arrived after the last streamed piece, read from the saved reply.
                val saved = vm.uiMessages.value.lastOrNull()?.takeIf { it.role == "assistant" && it.id !in before }
                val text = saved?.let { spokenText(it.toolBlocks, it.content) }.orEmpty()
                if (text.length > written) {
                    chunker.add(text.substring(written))
                    reply.value = text
                }
                chunker.flush()
                if (chunker.sentAny) {
                    tts.finish()
                    withTimeoutOrNull(SPEECH_TIMEOUT_MS) { spoken.await() }
                    playback.close()
                    player.join()
                    audio.drain()
                } else {
                    tts.cancel()
                    playback.close()
                    if (problem.value == null) problem.value = vm.error.value ?: context.getString(R.string.nm_call_error_no_reply)
                    delay(PAUSE_AFTER_SILENT_TURN_MS)
                }
            }
            // Mosaic: the person cut in: whatever the reply was doing stops where it is.
            val watch = launch { cut.await(); work.cancel() }
            work.join()
            watch.cancel()
        }
        cutIn = null
        if (cut.isCompleted) {
            tts.cancel()
            playback.cancel() // drops what is queued, unlike close
            player.cancel()
            audio.stopPlayback()
            player.join()
            withContext(Dispatchers.Main) { if (vm.isStreaming.value) vm.cancelStream() }
        }
        synthesizer = null
    }

    private fun fail(message: String) {
        problem.value = message
        _phase.value = CallPhase.ENDED
    }

    private fun describe(failure: StreamFailure): String = when (failure) {
        is StreamFailure.Refused -> context.getString(R.string.nm_call_error_refused, failure.httpCode)
        is StreamFailure.Network -> context.getString(R.string.nm_call_error_network, failure.reason)
        is StreamFailure.Task -> context.getString(R.string.nm_call_error_task, failure.message.ifBlank { failure.code })
    }.also { Log.w(TAG, it) }

    companion object {
        private const val TAG = "CallSession"
        private const val ADDENDUM_TAG = "voice-call"
        private const val START_TIMEOUT_MS = 15_000L
        private const val SPEECH_TIMEOUT_MS = 120_000L
        private const val PAUSE_AFTER_SILENT_TURN_MS = 1_500L

        /** For the model only, so it is not translated; it answers in the person's language. */
        private const val CALL_PROMPT = """Voice call in progress. The user is talking to you by voice and hears your reply through text-to-speech, not on a screen.
- Reply in the user's language, as natural spoken sentences.
- Keep it short: one to three sentences unless the user asks for more.
- No Markdown, lists, tables, code, emoji, links or stage directions.
- If something needs a tool or takes a while, say so in one short sentence first."""

        /**
         * Mosaic: whether what the recogniser heard while the agent was answering is the person
         * speaking over it: at least two letters or characters, and under half of it found in the
         * words being said (on the loudspeaker the agent's own voice can come back to the
         * microphone). Chinese is compared by pairs of characters, other languages by words.
         */
        fun cutsIn(heard: String, spoken: String): Boolean {
            val said = heard.lowercase().filter { it.isLetterOrDigit() || it.isWhitespace() }
            if (said.count { it.isLetterOrDigit() } < 2) return false
            val reply = spoken.lowercase()
            if (reply.isBlank()) return true
            val han = said.any { Character.UnicodeScript.of(it.code) == Character.UnicodeScript.HAN }
            val pieces = if (han) said.filterNot { it.isWhitespace() }.windowed(2) else said.split(' ').filter { it.isNotBlank() }
            if (pieces.isEmpty()) return true
            return pieces.count { it in reply } * 2 < pieces.size
        }

        /** The words of a reply: its text blocks in order (tool steps and thinking are not spoken). */
        fun spokenText(blocks: List<AssistantBlock>, content: String): String {
            val text = blocks.filter { it.kind == "text" }.joinToString("") { it.content }
            return text.ifEmpty { content }
        }
    }
}

/**
 * Cuts the streaming reply into pieces for the synthesiser: at the first punctuation mark, so the
 * first words sound as soon as there is a phrase, or after [MAX_CHARS] when no mark comes. An ASCII
 * period, comma or colon counts only with a space after it, so "3.5" or "10:30" stays whole.
 * Markdown and links are cleaned out of each piece.
 */
private class SpeechChunker(private val emit: (String) -> Unit) {
    private val buffer = StringBuilder()
    var sentAny = false
        private set

    fun add(text: String) {
        buffer.append(text)
        while (true) {
            val cut = cutPoint() ?: break
            send(buffer.substring(0, cut))
            buffer.delete(0, cut)
        }
    }

    fun flush() {
        if (buffer.isNotEmpty()) send(buffer.toString())
        buffer.clear()
    }

    private fun cutPoint(): Int? {
        for (i in buffer.indices) {
            val c = buffer[i]
            if (c in BREAKS) return i + 1
            if (c in SOFT_BREAKS && i + 1 < buffer.length && buffer[i + 1].isWhitespace()) return i + 1
        }
        return if (buffer.length >= MAX_CHARS) buffer.length else null
    }

    private fun send(raw: String) {
        val clean = VoiceTextSanitizer.sanitize(raw).trim()
        if (clean.isEmpty()) return
        emit(clean)
        sentAny = true
    }

    private companion object {
        const val BREAKS = "，。！？；：、!?;\n"
        const val SOFT_BREAKS = ".,:"
        const val MAX_CHARS = 24
    }
}
