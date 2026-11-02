package io.github.nanomuse.identity

import android.content.Context
import androidx.compose.ui.graphics.asAndroidBitmap
import io.github.nanomuse.avatar.AvatarStore
import io.github.nanomuse.avatar.OwnClip
import io.github.nanomuse.ui.avatar.AgentMood
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import android.graphics.Bitmap
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import androidx.core.graphics.drawable.toBitmap
import com.openminis.app.R
import com.openminis.app.agent.SoulMetadata
import com.openminis.app.agent.SoulStore

/**
 * The agent's name and face, for every surface outside the chat screen.
 *
 * SOUL.md is the single source of truth for the name (see [SoulStore]); this object only adds
 * the two things notification code needs: a name that is correct even in a process that never
 * warmed [SoulStore.cachedMetadata], and the built-in face as a large-icon bitmap.
 */
object NanoMuseIdentity {

    /** The current name, read from disk so receivers and services get the live value. */
    fun name(context: Context): String {
        val cached = SoulStore.cachedMetadata.value.name.trim()
        return cached.ifEmpty { SoulMetadata.DEFAULT.name }
    }

    /** True until the user (or the agent) has renamed it. */
    fun hasDefaultName(context: Context): Boolean = name(context) == SoulMetadata.DEFAULT.name

    @Volatile private var cachedFace: Bitmap? = null

    private val revisionState = MutableStateFlow(0L)
    val revision: StateFlow<Long> = revisionState
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private var initialized = false

    /** 后台缩放当前宠物，通知构建只读取小图缓存。 */
    @Synchronized
    fun init(context: Context) {
        if (initialized) return
        initialized = true
        val app = context.applicationContext
        scope.launch {
            combine(AvatarStore.current, OwnClip.poster, OwnClip.moodPosters,
                com.openminis.app.service.SessionActivityTracker.activeSessions) { face, poster, moodPosters, active ->
                val mood = if (active.isEmpty()) AgentMood.IDLE else AgentMood.WORKING
                moodPosters[mood] ?: poster ?: face?.forMood(mood)
            }.collect { selected ->
                cachedFace = selected?.asAndroidBitmap()?.let { Bitmap.createScaledBitmap(it, FACE_PX, FACE_PX, true) }
                    ?: ContextCompat.getDrawable(app, R.drawable.nm_avatar_idle)?.toBitmap(FACE_PX, FACE_PX)
                revisionState.value++
            }
        }
    }

    /** 当前宠物的小图快照，界面线程不再读盘或解码。 */
    fun face(context: Context): Bitmap? = cachedFace

    /** Puts the face on a notification the way Muse does: the agent is the sender. */
    fun NotificationCompat.Builder.withFace(context: Context): NotificationCompat.Builder {
        face(context)?.let { setLargeIcon(it) }
        return this
    }

    private const val FACE_PX = 192
}
