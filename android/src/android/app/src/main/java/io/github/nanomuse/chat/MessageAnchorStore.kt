package io.github.nanomuse.chat

import android.content.Context
import android.content.SharedPreferences
import com.openminis.app.ui.chat.ChatMessage
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/** 本地书签只存消息身份，读取和写入都在后台串行完成。 */
class MessageAnchorStore internal constructor(private val openPreferences: () -> SharedPreferences) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val lock = Mutex()
    private val snapshots = MutableStateFlow<Map<String, Set<String>>>(emptyMap())
    val state: StateFlow<Map<String, Set<String>>> = snapshots
    private val loaded = MutableStateFlow(false)
    val ready: StateFlow<Boolean> = loaded
    private var hasLoaded = false
    private val prefs by lazy(openPreferences)

    init { scope.launch { runCatching { lock.withLock { load() } }; loaded.value = true } }

    /** 切换合并消息的书签时同时处理所有来源行，避免看似取消后又出现。 */
    suspend fun toggle(sessionId: String, message: ChatMessage) = withContext(Dispatchers.IO) {
        lock.withLock {
            load()
            val aliases = message.sourceDbIds.toSet() + message.id
            val old = snapshots.value[sessionId].orEmpty()
            val next = if (old.any { it in aliases }) old - aliases else old + anchorIdentity(message)
            check(prefs.edit().putStringSet("anchors:$sessionId", next).commit())
            snapshots.value = snapshots.value + (sessionId to next)
        }
    }

    private fun load() {
        if (hasLoaded) return
        snapshots.value = prefs.all.entries.filter { it.key.startsWith("anchors:") }.associate { entry ->
            entry.key.removePrefix("anchors:") to ((entry.value as? Set<*>)?.filterIsInstance<String>()?.toSet().orEmpty())
        }
        hasLoaded = true
    }

    companion object {
        @Volatile private var instance: MessageAnchorStore? = null
        /** 返回当前 App 共用的本地书签库。 */
        fun get(context: Context): MessageAnchorStore {
            val app = context.applicationContext
            return instance ?: synchronized(this) {
                instance ?: MessageAnchorStore {
                    app.getSharedPreferences("nm_message_anchors", Context.MODE_PRIVATE)
                }.also { instance = it }
            }
        }
    }
}
