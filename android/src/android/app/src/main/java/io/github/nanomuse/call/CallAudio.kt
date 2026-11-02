package io.github.nanomuse.call

import android.annotation.SuppressLint
import android.content.Context
import android.media.AudioAttributes
import android.media.AudioDeviceInfo
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.AudioTrack
import android.media.MediaRecorder
import android.media.audiofx.AcousticEchoCanceler
import android.media.audiofx.AudioEffect
import android.media.audiofx.NoiseSuppressor
import android.os.Build
import android.os.SystemClock
import android.util.Log
import kotlinx.coroutines.delay

/**
 * The phone side of a call: the microphone in at [MIC_RATE] with the platform's echo canceller and
 * noise suppressor where the phone has them, speech out at [SPEECH_RATE], and the whole call routed
 * like a phone call: the earpiece, or the loudspeaker when the person chooses it.
 */
class CallAudio(context: Context) {
    private val audioManager = context.getSystemService(AudioManager::class.java)
    private var previousMode = AudioManager.MODE_NORMAL
    // The microphone is read on one thread and the speech written on another while hanging up
    // happens on the main thread: each is released under its lock, after a stop has unblocked it.
    private val micLock = Any()
    private val trackLock = Any()
    @Volatile private var record: AudioRecord? = null
    private val effects = mutableListOf<AudioEffect>()
    @Volatile private var track: AudioTrack? = null
    @Volatile private var framesWritten = 0L
    @Volatile private var closed = false
    @Volatile private var cut = false // Mosaic: the reply was cut short; a write in progress stops

    fun startRouting(speaker: Boolean) {
        previousMode = audioManager.mode
        audioManager.mode = AudioManager.MODE_IN_COMMUNICATION
        setSpeaker(speaker)
    }

    fun setSpeaker(on: Boolean) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val wanted = if (on) AudioDeviceInfo.TYPE_BUILTIN_SPEAKER else AudioDeviceInfo.TYPE_BUILTIN_EARPIECE
            audioManager.availableCommunicationDevices.firstOrNull { it.type == wanted }
                ?.let { audioManager.setCommunicationDevice(it) }
        } else {
            legacySpeaker(on)
        }
    }

    @Suppress("DEPRECATION")
    private fun legacySpeaker(on: Boolean) {
        audioManager.isSpeakerphoneOn = on
    }

    /** Starts the microphone; false when the phone refuses it. The call page has asked for RECORD_AUDIO first. */
    @SuppressLint("MissingPermission")
    fun openMic(): Boolean {
        val min = AudioRecord.getMinBufferSize(MIC_RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
        val mic = runCatching {
            AudioRecord(
                MediaRecorder.AudioSource.VOICE_COMMUNICATION,
                MIC_RATE,
                AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
                maxOf(min, MIC_FRAME_BYTES * 8),
            )
        }.getOrNull() ?: return false
        if (mic.state != AudioRecord.STATE_INITIALIZED) {
            mic.release()
            return false
        }
        synchronized(micLock) {
            if (closed) {
                mic.release()
                return false
            }
            if (AcousticEchoCanceler.isAvailable()) AcousticEchoCanceler.create(mic.audioSessionId)?.let { it.enabled = true; effects += it }
            if (NoiseSuppressor.isAvailable()) NoiseSuppressor.create(mic.audioSessionId)?.let { it.enabled = true; effects += it }
            mic.startRecording()
            record = mic
        }
        return true
    }

    /** Reads the next piece of the microphone into [buffer]: the byte count, or a negative number once the call is over. */
    fun readMic(buffer: ByteArray): Int = synchronized(micLock) {
        record?.read(buffer, 0, buffer.size) ?: -1
    }

    /** Plays one piece of synthesised PCM, blocking while the buffer is full. Nothing once the call is over. */
    fun play(pcm: ByteArray) {
        synchronized(trackLock) {
            if (closed) return
            val out = track ?: openTrack() ?: return
            var offset = 0
            while (!closed && !cut && offset < pcm.size) {
                val n = out.write(pcm, offset, minOf(pcm.size - offset, MIC_FRAME_BYTES))
                if (n <= 0) break
                offset += n
            }
            framesWritten += offset / 2
        }
    }

    private fun openTrack(): AudioTrack? {
        return runCatching {
            val min = AudioTrack.getMinBufferSize(SPEECH_RATE, AudioFormat.CHANNEL_OUT_MONO, AudioFormat.ENCODING_PCM_16BIT)
            AudioTrack.Builder()
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                        .build(),
                )
                .setAudioFormat(
                    AudioFormat.Builder()
                        .setSampleRate(SPEECH_RATE)
                        .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                        .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                        .build(),
                )
                .setBufferSizeInBytes(min * 4)
                .setTransferMode(AudioTrack.MODE_STREAM)
                .build()
                .also {
                    it.play()
                    framesWritten = 0
                    track = it
                }
        }.onFailure { Log.w(TAG, "speech output unavailable", it) }.getOrNull()
    }

    /** Waits until everything written so far has been heard, or [timeoutMs] passes. */
    suspend fun drain(timeoutMs: Long = 30_000) {
        val out = track ?: return
        val deadline = SystemClock.elapsedRealtime() + timeoutMs
        while (!closed && SystemClock.elapsedRealtime() < deadline) {
            val heard = out.playbackHeadPosition.toLong() and 0xFFFFFFFFL
            if (heard >= framesWritten) break
            delay(30)
        }
    }

    /**
     * Mosaic: stops the speech at once when the person cuts in: what is queued in the track is
     * dropped, a write in progress returns, and the track is ready for the next reply.
     */
    fun stopPlayback() {
        cut = true
        track?.let { runCatching { it.pause(); it.flush() } }
        synchronized(trackLock) {
            track?.let { runCatching { it.play() } }
            framesWritten = 0
            cut = false
        }
    }

    fun release() {
        closed = true
        // Unblock a read or write in progress first, then release under the lock it held.
        record?.let { runCatching { it.stop() } }
        track?.let { runCatching { it.pause(); it.flush() } }
        synchronized(micLock) {
            record?.release()
            record = null
            effects.forEach { it.release() }
            effects.clear()
        }
        synchronized(trackLock) {
            track?.let { runCatching { it.stop() }; it.release() }
            track = null
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) audioManager.clearCommunicationDevice() else legacySpeaker(false)
        audioManager.mode = previousMode
    }

    companion object {
        private const val TAG = "CallAudio"
        const val MIC_RATE = 16_000
        const val SPEECH_RATE = 24_000

        /** 40 ms of 16 kHz mono PCM16. */
        const val MIC_FRAME_BYTES = MIC_RATE / 25 * 2
    }
}
