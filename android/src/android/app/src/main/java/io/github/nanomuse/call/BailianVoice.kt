package io.github.nanomuse.call

import android.util.Base64
import com.openminis.app.provider.voice.VoiceInputRequest
import com.openminis.app.provider.voice.VoiceInputResponse
import com.openminis.app.provider.voice.VoiceOutputRequest
import com.openminis.app.provider.voice.VoiceProvider
import com.openminis.app.provider.voice.VoiceProviderException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.net.URI
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Mosaic: speech recognition and synthesis on Alibaba Cloud Model Studio (Bailian) for voice
 * input, read-aloud and the provider's quick test. Bailian's OpenAI-compatible mode has no
 * `/audio/transcriptions` or `/audio/speech` (hence the HTTP 404 on speech), and its chat models
 * take audio only as a URL or a `data:` URL (hence "The provided URL does not appear to be valid"
 * for raw base64). So each model family goes where Bailian serves it:
 *
 * - Paraformer and Fun-ASR real-time recognisers, and CosyVoice: the WebSocket the voice call uses.
 * - Qwen-ASR and the omni models: chat completions, the recording as `data:audio/wav;base64,…`.
 * - Qwen-TTS: the native multimodal-generation endpoint, which returns the address of a WAV file.
 *
 * Anything else says which models work instead of failing with a bare HTTP code.
 */
object BailianVoice {
    private const val SOCKET_RATE = 16_000
    private const val SPEECH_RATE = 24_000
    private const val QWEN_TTS_MAX_CHARS = 600
    private const val COSYVOICE_PIECE_CHARS = 1_000

    /** `wss://<host>/api-ws/v1/inference` for the host of the provider's address (Beijing, Singapore or a workspace). */
    fun socketEndpoint(baseURL: String): String = "wss://${host(baseURL)}/api-ws/v1/inference"

    private fun host(baseURL: String): String =
        runCatching { URI(baseURL.trim()).host }.getOrNull()?.takeIf { it.isNotBlank() } ?: "dashscope.aliyuncs.com"

    suspend fun transcribe(baseURL: String, apiKey: String?, request: VoiceInputRequest, fallbackModel: String): VoiceInputResponse {
        val key = apiKey?.takeIf { it.isNotBlank() } ?: throw VoiceProviderException.Auth()
        val model = (request.model ?: fallbackModel).trim()
        val id = model.lowercase()
        return when {
            "realtime" in id && ("paraformer" in id || "fun-asr" in id) -> overSocket(socketEndpoint(baseURL), key, model, request.audioData)
            "omni" in id || ("qwen" in id && ("asr" in id || "audio" in id)) -> inChat(baseURL, key, model, request.audioData)
            else -> throw IOException(
                "Model Studio serves $model neither as real-time recognition nor through chat. " +
                    "Use fun-asr-realtime, paraformer-realtime-v2 or qwen3-asr-flash for speech to text.",
            )
        }
    }

    suspend fun synthesize(baseURL: String, apiKey: String?, request: VoiceOutputRequest, fallbackModel: String): ByteArray {
        val key = apiKey?.takeIf { it.isNotBlank() } ?: throw VoiceProviderException.Auth()
        val model = (request.model ?: fallbackModel).trim()
        val id = model.lowercase()
        // The callers pass the model id as the voice (other vendors' voices are model entries); that is no Bailian voice.
        val asked = request.voice?.trim()?.takeIf { it.isNotEmpty() && !it.equals(model, ignoreCase = true) }
        return when {
            id.startsWith("cosyvoice") -> cosyVoice(socketEndpoint(baseURL), key, model, asked ?: defaultCosyVoice(id), request.input)
            "qwen" in id && "tts" in id -> qwenTts(host(baseURL), key, model, asked ?: "Cherry", request.input)
            else -> throw IOException(
                "Model Studio does not synthesise speech with $model here. Use cosyvoice-v3-flash or qwen3-tts-flash for text to speech.",
            )
        }
    }

    /** A system voice of the model's generation: v3 voices have plain names, v2 voices end in _v2. */
    private fun defaultCosyVoice(id: String): String = when {
        "v3" in id -> CallSettings.DEFAULT_VOICE
        "v2" in id -> "longxiaochun_v2"
        else -> "longxiaochun"
    }

    // -- Recognition ----------------------------------------------------------

    private suspend fun overSocket(endpoint: String, key: String, model: String, wav: ByteArray): VoiceInputResponse {
        val pcm = toMono16k(wav)
        val said = StringBuilder()
        val done = CompletableDeferred<Ended>()
        val settings = CallSettings(endpoint, model, CallSettings.DEFAULT_TTS_MODEL, CallSettings.DEFAULT_VOICE, CallSettings.DEFAULT_SILENCE_MS)
        val asr = StreamingRecognizer(settings, key, SOCKET_RATE, object : StreamingRecognizer.Events {
            override fun onPartial(text: String) = Unit
            override fun onSentence(text: String) { synchronized(said) { said.append(text) } }
            override fun onFailure(failure: StreamFailure) { done.complete(Ended(failure)) }
            override fun onDone() { done.complete(Ended(null)) }
        })
        try {
            // 400 ms a frame, a little faster than real time: the recogniser holds what comes before it is ready.
            val step = SOCKET_RATE / 10 * 2 * 4
            var at = 0
            while (at < pcm.size) {
                asr.send(pcm.copyOfRange(at, minOf(at + step, pcm.size)))
                at += step
                delay(20)
            }
            asr.finish()
            val ended = withTimeoutOrNull(30_000) { done.await() }
                ?: throw IOException("Model Studio did not finish the recognition within 30 seconds.")
            fail(ended.failure)
        } finally {
            asr.cancel()
        }
        return VoiceInputResponse(text = synchronized(said) { said.toString().trim() })
    }

    private suspend fun inChat(baseURL: String, key: String, model: String, wav: ByteArray): VoiceInputResponse = withContext(Dispatchers.IO) {
        val omni = "omni" in model.lowercase()
        val audio = JSONObject().put("type", "input_audio").put(
            "input_audio",
            JSONObject().put("data", "data:audio/wav;base64," + Base64.encodeToString(wav, Base64.NO_WRAP)).put("format", "wav"),
        )
        val content = JSONArray().put(audio)
        val messages = JSONArray()
        if (omni) {
            // An omni model is a chat model: it is asked to act as a transcriber. Qwen-ASR transcribes by itself.
            messages.put(JSONObject().put("role", "system").put("content", "You are a speech-to-text engine. Output only the exact words spoken in the audio, in the language spoken, with nothing else."))
            content.put(JSONObject().put("type", "text").put("text", "Transcribe this audio."))
        }
        messages.put(JSONObject().put("role", "user").put("content", content))
        val body = JSONObject().put("model", model).put("messages", messages)
        // Omni models answer only as a stream on Bailian.
        if (omni) body.put("stream", true).put("modalities", JSONArray().put("text"))
        else body.put("stream", false).put("asr_options", JSONObject().put("enable_itn", false))
        val base = baseURL.trimEnd('/').let { if (it.endsWith("/v1")) it else "$it/v1" } // the address may be saved without /v1
        val request = Request.Builder()
            .url("$base/chat/completions")
            .header("Authorization", "Bearer $key")
            .post(body.toString().toRequestBody("application/json".toMediaType()))
            .build()
        VoiceProvider.httpClient.newCall(request).execute().use { response ->
            if (!response.isSuccessful) throw httpFailure(response.code, response.body?.bytes())
            val source = response.body?.source() ?: throw VoiceProviderException.NoAudioData()
            if (!omni) {
                val obj = JSONObject(source.readUtf8())
                val text = obj.optJSONArray("choices")?.optJSONObject(0)?.optJSONObject("message")?.optString("content").orEmpty()
                return@withContext VoiceInputResponse(text = text.trim())
            }
            val text = StringBuilder()
            while (true) {
                val line = source.readUtf8Line() ?: break
                val data = line.removePrefix("data:").trim().takeIf { line.startsWith("data:") } ?: continue
                if (data == "[DONE]") break
                runCatching { JSONObject(data) }.getOrNull()?.optJSONArray("choices")?.optJSONObject(0)
                    ?.optJSONObject("delta")?.optString("content")?.let(text::append)
            }
            VoiceInputResponse(text = text.toString().trim())
        }
    }

    // -- Synthesis --------------------------------------------------------------

    private suspend fun cosyVoice(endpoint: String, key: String, model: String, voice: String, text: String): ByteArray {
        val pcm = ByteArrayOutputStream()
        val done = CompletableDeferred<Ended>()
        val settings = CallSettings(endpoint, CallSettings.DEFAULT_ASR_MODEL, model, voice, CallSettings.DEFAULT_SILENCE_MS)
        val tts = StreamingSynthesizer(settings, key, SPEECH_RATE, object : StreamingSynthesizer.Events {
            override fun onAudio(pcm16: ByteArray) { synchronized(pcm) { pcm.write(pcm16) } }
            override fun onDone() { done.complete(Ended(null)) }
            override fun onFailure(failure: StreamFailure) { done.complete(Ended(failure)) }
        })
        try {
            text.chunked(COSYVOICE_PIECE_CHARS).forEach(tts::push)
            tts.finish()
            val ended = withTimeoutOrNull(120_000) { done.await() }
                ?: throw IOException("Model Studio did not finish the speech within two minutes.")
            fail(ended.failure)
        } finally {
            tts.cancel()
        }
        val audio = synchronized(pcm) { pcm.toByteArray() }
        if (audio.isEmpty()) throw VoiceProviderException.NoAudioData()
        return VoiceProvider.wrapPcm16InWav(audio, SPEECH_RATE)
    }

    /** Qwen-TTS takes up to 600 characters a call; longer text is said piece by piece and joined into one WAV. */
    private suspend fun qwenTts(host: String, key: String, model: String, voice: String, text: String): ByteArray = withContext(Dispatchers.IO) {
        var rate = SPEECH_RATE
        val joined = ByteArrayOutputStream()
        for (piece in text.chunked(QWEN_TTS_MAX_CHARS)) {
            val body = JSONObject().put("model", model).put("input", JSONObject().put("text", piece).put("voice", voice))
            val request = Request.Builder()
                .url("https://$host/api/v1/services/aigc/multimodal-generation/generation")
                .header("Authorization", "Bearer $key")
                .post(body.toString().toRequestBody("application/json".toMediaType()))
                .build()
            val audio = VoiceProvider.httpClient.newCall(request).execute().use { response ->
                val bytes = response.body?.bytes()
                if (!response.isSuccessful) throw httpFailure(response.code, bytes)
                val out = JSONObject(String(bytes ?: ByteArray(0), Charsets.UTF_8)).optJSONObject("output")?.optJSONObject("audio")
                val inline = out?.optString("data").orEmpty()
                if (inline.isNotEmpty()) Base64.decode(inline, Base64.DEFAULT)
                else {
                    val url = out?.optString("url")?.takeIf { it.isNotBlank() } ?: throw VoiceProviderException.NoAudioData()
                    VoiceProvider.httpClient.newCall(Request.Builder().url(url).build()).execute().use { file ->
                        if (!file.isSuccessful) throw httpFailure(file.code, null)
                        file.body?.bytes() ?: throw VoiceProviderException.NoAudioData()
                    }
                }
            }
            val wav = Wav.read(audio)
            if (wav != null) { rate = wav.rate; joined.write(wav.pcm) } else joined.write(audio)
        }
        VoiceProvider.wrapPcm16InWav(joined.toByteArray(), rate)
    }

    // -- Helpers ----------------------------------------------------------------

    /** How a stream ended: [failure] null when it finished normally. */
    private class Ended(val failure: StreamFailure?)

    private fun fail(failure: StreamFailure?) {
        when (failure) {
            null -> Unit
            is StreamFailure.Refused -> throw VoiceProviderException.Auth()
            is StreamFailure.Network -> throw IOException("Could not reach Model Studio: ${failure.reason}")
            is StreamFailure.Task -> throw IOException("Model Studio: ${failure.message.ifBlank { failure.code }}")
        }
    }

    private fun httpFailure(code: Int, body: ByteArray?): Exception =
        if (code == 401 || code == 403) VoiceProviderException.Auth() else VoiceProviderException.Http(code, body)

    /** The recording as 16 kHz mono PCM16, what the real-time recognisers take. */
    private fun toMono16k(audio: ByteArray): ByteArray {
        val wav = Wav.read(audio) ?: return audio
        val samples = ByteBuffer.wrap(wav.pcm).order(ByteOrder.LITTLE_ENDIAN).asShortBuffer()
        val frames = samples.remaining() / wav.channels
        val mono = ShortArray(frames) { samples.get(it * wav.channels) }
        if (wav.rate == SOCKET_RATE) return ByteBuffer.allocate(frames * 2).order(ByteOrder.LITTLE_ENDIAN).apply { asShortBuffer().put(mono) }.array()
        val outFrames = (frames.toLong() * SOCKET_RATE / wav.rate).toInt()
        val out = ByteBuffer.allocate(outFrames * 2).order(ByteOrder.LITTLE_ENDIAN)
        for (i in 0 until outFrames) {
            val at = i.toDouble() * wav.rate / SOCKET_RATE
            val a = mono[minOf(at.toInt(), frames - 1)]
            val b = mono[minOf(at.toInt() + 1, frames - 1)]
            out.putShort((a + (b - a) * (at - at.toInt())).toInt().toShort())
        }
        return out.array()
    }

    /** The PCM16 inside a RIFF/WAVE file, its rate and channel count; null for anything else. */
    private class Wav(val pcm: ByteArray, val rate: Int, val channels: Int) {
        companion object {
            fun read(bytes: ByteArray): Wav? {
                if (bytes.size < 12 || String(bytes, 0, 4, Charsets.US_ASCII) != "RIFF" || String(bytes, 8, 4, Charsets.US_ASCII) != "WAVE") return null
                val b = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
                var at = 12
                var rate = 0
                var channels = 1
                var bits = 16
                while (at + 8 <= bytes.size) {
                    val id = String(bytes, at, 4, Charsets.US_ASCII)
                    val size = b.getInt(at + 4)
                    val start = at + 8
                    if (size < 0 || start + size > bytes.size) {
                        // A streamed file may leave the data size open: take the rest.
                        if (id == "data" && rate > 0 && bits == 16) return Wav(bytes.copyOfRange(start, bytes.size), rate, channels)
                        return null
                    }
                    when (id) {
                        "fmt " -> {
                            channels = b.getShort(start + 2).toInt().coerceAtLeast(1)
                            rate = b.getInt(start + 4)
                            bits = b.getShort(start + 14).toInt()
                        }
                        "data" -> return if (rate > 0 && bits == 16) Wav(bytes.copyOfRange(start, start + size), rate, channels) else null
                    }
                    at = start + size + (size and 1)
                }
                return null
            }
        }
    }
}
