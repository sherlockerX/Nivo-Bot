package com.openminis.app.ui.chat

import android.content.Context
import com.openminis.app.speech.ReadAloudPlayer
// nanoMuse: 选区朗读继承所属教练消息的系统语音约束。
import com.openminis.app.speech.VoiceOutputState
import io.github.nanomuse.speech.SpeechOutputPolicy

/**
 * [T-android-selection-readaloud] Defers [ReadAloudPlayer] construction until
 * something is actually spoken.
 *
 * Constructing the player binds an Android TextToSpeech engine (see
 * `TextToSpeechManager.init`), so building one eagerly for every ChatScreen
 * would pay that cost for the large majority of sessions that never use the
 * selection toolbar's Read Aloud action. [shutdown] is safe to call when
 * nothing was ever created.
 */
internal class LazyReadAloudPlayer(context: Context) {

    private val appContext = context.applicationContext

    @Volatile
    private var player: ReadAloudPlayer? = null
    // nanoMuse: 路由改变时先释放旧实例，不同时保留两个音频所有者。
    private var playerPolicy: SpeechOutputPolicy? = null

    // nanoMuse: 教练选区只走系统TTS，普通选区保留原有全局语音选择。
    /** 朗读选中文字，并停止其他来源当前正在播放的声音。 */
    fun speak(text: String, policy: SpeechOutputPolicy = SpeechOutputPolicy.FOLLOW_SELECTION) {
        if (text.isBlank()) return
        // nanoMuse: 新建的播放器在构造时就登记为当前播放器，所以先记下原来在播放的那个，再创建或复用。
        val previous = VoiceOutputState.activePlayer
        val selected = synchronized(this) {
            val current = player
            if (current != null && playerPolicy == policy) current else {
                current?.shutdown()
                player = null
                playerPolicy = policy
                ReadAloudPlayer(appContext, policy = policy).also { player = it }
            }
        }
        previous?.takeIf { it !== selected }?.stop()
        VoiceOutputState.registerPlayer(selected)
        selected.speak(text)
    }

    /**
     * [T-android-readaloud-stop-stale] Stop whatever is currently being read.
     *
     * Deliberately does NOT bind an engine: if nothing has ever been spoken
     * there is nothing to stop, and constructing a TTS engine here would undo
     * the whole point of the lazy player (an unused ChatScreen never binds
     * one). Idempotent and safe to call on every new reply.
     */
    fun stop() {
        player?.stop()
    }

    /** Release the engine if one was ever bound. Idempotent. */
    fun shutdown() {
        synchronized(this) {
            player?.shutdown()
            player = null
            playerPolicy = null // nanoMuse: 销毁页面时清除旧路由。
        }
    }
}
