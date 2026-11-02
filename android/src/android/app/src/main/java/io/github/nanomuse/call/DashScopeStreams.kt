package io.github.nanomuse.call

import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString
import okio.ByteString.Companion.toByteString
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID
import java.util.concurrent.TimeUnit

/** Why a Bailian stream stopped: the key was refused, the network failed, or the task reported an error. */
sealed interface StreamFailure {
    data class Refused(val httpCode: Int) : StreamFailure
    data class Network(val reason: String) : StreamFailure
    data class Task(val code: String, val message: String) : StreamFailure
}

/**
 * The DashScope duplex WebSocket protocol shared by recognition and synthesis: a `run-task` with
 * the model and parameters, `task-started` from the server, the data, a `finish-task`, and
 * `task-finished` (or `task-failed`). One task per socket here, so a failure never leaks into the
 * next turn.
 */
private object DashScope {
    val client: OkHttpClient by lazy {
        OkHttpClient.Builder()
            .connectTimeout(10, TimeUnit.SECONDS)
            .readTimeout(0, TimeUnit.MILLISECONDS)
            .pingInterval(15, TimeUnit.SECONDS)
            .build()
    }

    fun open(endpoint: String, apiKey: String, listener: WebSocketListener): WebSocket = client.newWebSocket(
        Request.Builder()
            .url(endpoint)
            .header("Authorization", "Bearer $apiKey")
            .header("user-agent", "Nicholasx-Android")
            .build(),
        listener,
    )

    fun header(action: String, taskId: String): JSONObject =
        JSONObject().put("action", action).put("task_id", taskId).put("streaming", "duplex")

    fun finishTask(taskId: String, cancel: Boolean = false): String = JSONObject()
        .put("header", header("finish-task", taskId))
        .put("payload", JSONObject().put("input", if (cancel) JSONObject().put("directive", "cancel") else JSONObject()))
        .toString()

    fun failure(t: Throwable, response: Response?): StreamFailure {
        val code = response?.code ?: 0
        return if (code == 401 || code == 403) StreamFailure.Refused(code) else StreamFailure.Network(t.message ?: t.javaClass.simpleName)
    }

    fun taskFailure(header: JSONObject): StreamFailure =
        StreamFailure.Task(header.optString("error_code"), header.optString("error_message"))
}

/**
 * One Fun-ASR real-time recognition task: 16 kHz mono PCM in, partial and final sentences out.
 * Audio sent before the server is ready is held and flushed on `task-started`, so the first words
 * are not lost to the handshake. A sentence ends after [CallSettings.silenceMs] of silence.
 */
class StreamingRecognizer(
    settings: CallSettings,
    apiKey: String,
    private val sampleRate: Int,
    private val events: Events,
) {
    interface Events {
        fun onPartial(text: String)
        fun onSentence(text: String)
        fun onFailure(failure: StreamFailure)

        /** The task finished after [finish]: every sentence has been delivered (BailianVoice waits for this). */
        fun onDone() {}
    }

    private val taskId = UUID.randomUUID().toString()
    private val lock = Any()
    private var socket: WebSocket? = null
    private var started = false
    @Volatile private var finished = false
    private val held = ArrayDeque<ByteString>()

    init {
        val runTask = JSONObject()
            .put("header", DashScope.header("run-task", taskId))
            .put(
                "payload",
                JSONObject()
                    .put("task_group", "audio")
                    .put("task", "asr")
                    .put("function", "recognition")
                    .put("model", settings.asrModel)
                    .put(
                        "parameters",
                        JSONObject()
                            .put("format", "pcm")
                            .put("sample_rate", sampleRate)
                            .put("max_sentence_silence", settings.silenceMs)
                            // Keeps the task alive through a long silence while the person thinks.
                            .put("heartbeat", true),
                    )
                    .put("input", JSONObject()),
            )
            .toString()
        socket = DashScope.open(settings.endpoint, apiKey, object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) {
                webSocket.send(runTask)
            }

            override fun onMessage(webSocket: WebSocket, text: String) {
                val message = runCatching { JSONObject(text) }.getOrNull() ?: return
                val header = message.optJSONObject("header") ?: return
                when (header.optString("event")) {
                    "task-started" -> synchronized(lock) {
                        started = true
                        while (held.isNotEmpty()) webSocket.send(held.removeFirst())
                        if (finished) webSocket.send(DashScope.finishTask(taskId))
                    }
                    "result-generated" -> {
                        val sentence = message.optJSONObject("payload")?.optJSONObject("output")?.optJSONObject("sentence") ?: return
                        if (sentence.optBoolean("heartbeat")) return
                        val said = sentence.optString("text").trim()
                        if (sentence.optBoolean("sentence_end")) events.onSentence(said) else events.onPartial(said)
                    }
                    "task-finished" -> {
                        events.onDone()
                        webSocket.close(1000, null)
                    }
                    "task-failed" -> {
                        synchronized(lock) { finished = true }
                        events.onFailure(DashScope.taskFailure(header))
                        webSocket.close(1000, null)
                    }
                }
            }

            // The server hung up mid-task without saying why; without this the turn would wait forever.
            override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
                if (!finished) events.onFailure(StreamFailure.Network(reason.ifBlank { "closed ($code)" }))
                webSocket.close(1000, null)
            }

            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                if (!finished) events.onFailure(DashScope.failure(t, response))
            }
        })
    }

    /** One frame of microphone audio. Held (up to about five seconds) until the task has started. */
    fun send(pcm: ByteArray) {
        synchronized(lock) {
            if (finished) return
            val frame = pcm.toByteString()
            if (started) {
                socket?.send(frame)
            } else {
                held.addLast(frame)
                while (held.size > MAX_HELD_FRAMES) held.removeFirst()
            }
        }
    }

    /** No more audio: the server sends what it still has and closes the task. */
    fun finish() {
        synchronized(lock) {
            if (finished) return
            finished = true
            if (started) socket?.send(DashScope.finishTask(taskId))
        }
    }

    fun cancel() {
        synchronized(lock) { finished = true }
        socket?.cancel()
    }

    private companion object {
        const val MAX_HELD_FRAMES = 125 // 125 frames of 40 ms
    }
}

/**
 * One CosyVoice synthesis task with streaming text input: text goes in piece by piece as the
 * model writes it, PCM comes back as soon as the service has a phrase. Text pushed before
 * `task-started` is queued in order.
 */
class StreamingSynthesizer(
    settings: CallSettings,
    apiKey: String,
    private val sampleRate: Int,
    private val events: Events,
) {
    interface Events {
        fun onAudio(pcm: ByteArray)
        fun onDone()
        fun onFailure(failure: StreamFailure)
    }

    private val taskId = UUID.randomUUID().toString()
    private val lock = Any()
    private var socket: WebSocket? = null
    private var started = false
    private var finishing = false
    @Volatile private var closed = false
    private val queued = ArrayList<String>()

    init {
        val runTask = JSONObject()
            .put("header", DashScope.header("run-task", taskId))
            .put(
                "payload",
                JSONObject()
                    .put("task_group", "audio")
                    .put("task", "tts")
                    .put("function", "SpeechSynthesizer")
                    .put("model", settings.ttsModel)
                    .put(
                        "parameters",
                        JSONObject()
                            .put("text_type", "PlainText")
                            .put("voice", settings.voice)
                            .put("format", "pcm")
                            .put("sample_rate", sampleRate)
                            .put("language_hints", JSONArray().put("zh")),
                    )
                    .put("input", JSONObject()),
            )
            .toString()
        socket = DashScope.open(settings.endpoint, apiKey, object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) {
                webSocket.send(runTask)
            }

            override fun onMessage(webSocket: WebSocket, bytes: ByteString) {
                if (!closed) events.onAudio(bytes.toByteArray())
            }

            override fun onMessage(webSocket: WebSocket, text: String) {
                val message = runCatching { JSONObject(text) }.getOrNull() ?: return
                val header = message.optJSONObject("header") ?: return
                when (header.optString("event")) {
                    "task-started" -> synchronized(lock) {
                        started = true
                        queued.forEach { webSocket.send(continueTask(it)) }
                        queued.clear()
                        if (finishing) webSocket.send(DashScope.finishTask(taskId))
                    }
                    "task-finished" -> {
                        synchronized(lock) { closed = true }
                        events.onDone()
                        webSocket.close(1000, null)
                    }
                    "task-failed" -> {
                        synchronized(lock) { closed = true }
                        events.onFailure(DashScope.taskFailure(header))
                        webSocket.close(1000, null)
                    }
                }
            }

            // The server hung up mid-task without saying why; without this the turn would wait for the timeout.
            override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
                if (!closed) events.onFailure(StreamFailure.Network(reason.ifBlank { "closed ($code)" }))
                webSocket.close(1000, null)
            }

            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                if (!closed) events.onFailure(DashScope.failure(t, response))
            }
        })
    }

    private fun continueTask(text: String): String = JSONObject()
        .put("header", DashScope.header("continue-task", taskId))
        .put("payload", JSONObject().put("input", JSONObject().put("text", text)))
        .toString()

    fun push(text: String) {
        if (text.isBlank()) return
        synchronized(lock) {
            if (finishing || closed) return
            if (started) socket?.send(continueTask(text)) else queued += text
        }
    }

    /** All the text is in; the server synthesises what it holds and ends with `task-finished`. */
    fun finish() {
        synchronized(lock) {
            if (finishing || closed) return
            finishing = true
            if (started) socket?.send(DashScope.finishTask(taskId))
        }
    }

    fun cancel() {
        synchronized(lock) { closed = true }
        socket?.cancel()
    }
}
