package io.github.nanomuse.call

import android.content.Context
import com.openminis.app.data.repository.ProviderRepository

/**
 * Where and how a voice call talks to Alibaba Cloud Model Studio (Bailian): the WebSocket address,
 * the recognition and speech models, the voice, and how long a pause ends the person's turn. Kept
 * in prefs and editable on the call page, since Bailian is moving keys to workspace addresses.
 */
data class CallSettings(
    val endpoint: String,
    val asrModel: String,
    val ttsModel: String,
    val voice: String,
    val silenceMs: Int,
) {
    companion object {
        /** Beijing; a workspace key may need `wss://<workspace>.cn-beijing.maas.aliyuncs.com/api-ws/v1/inference`. */
        const val DEFAULT_ENDPOINT = "wss://dashscope.aliyuncs.com/api-ws/v1/inference"
        const val DEFAULT_ASR_MODEL = "fun-asr-realtime"

        /** CosyVoice v3.5 has no system voices (cloned or designed only), so the default is v3 flash. */
        const val DEFAULT_TTS_MODEL = "cosyvoice-v3-flash"
        const val DEFAULT_VOICE = "longanyang"
        const val DEFAULT_SILENCE_MS = 800

        /** The range Fun-ASR accepts for `max_sentence_silence`. */
        val SILENCE_RANGE = 200..6000

        private const val PREFS = "nm_call"

        fun load(context: Context): CallSettings {
            val p = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            return CallSettings(
                endpoint = p.getString("endpoint", null)?.takeIf { it.isNotBlank() } ?: DEFAULT_ENDPOINT,
                asrModel = p.getString("asr_model", null)?.takeIf { it.isNotBlank() } ?: DEFAULT_ASR_MODEL,
                ttsModel = p.getString("tts_model", null)?.takeIf { it.isNotBlank() } ?: DEFAULT_TTS_MODEL,
                voice = p.getString("voice", null)?.takeIf { it.isNotBlank() } ?: DEFAULT_VOICE,
                silenceMs = p.getInt("silence_ms", DEFAULT_SILENCE_MS).coerceIn(SILENCE_RANGE),
            )
        }

        fun save(context: Context, settings: CallSettings) {
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
                .putString("endpoint", settings.endpoint.trim())
                .putString("asr_model", settings.asrModel.trim())
                .putString("tts_model", settings.ttsModel.trim())
                .putString("voice", settings.voice.trim())
                .putInt("silence_ms", settings.silenceMs.coerceIn(SILENCE_RANGE))
                .apply()
        }
    }
}

/**
 * The Bailian key the person already gave the app: the first enabled provider on a DashScope or
 * Model Studio address. Calls store no key of their own.
 */
fun bailianKey(repo: ProviderRepository): String? = repo.instances
    .filter { instance ->
        val base = instance.customBaseURL.orEmpty().lowercase()
        instance.isEnabled && ("dashscope" in base || "maas.aliyuncs.com" in base)
    }
    .firstNotNullOfOrNull { repo.loadApiKey(it.id)?.takeIf { key -> key.isNotBlank() } }
