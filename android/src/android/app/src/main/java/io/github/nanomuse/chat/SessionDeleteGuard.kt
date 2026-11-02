package io.github.nanomuse.chat

import android.content.Context
import com.openminis.app.service.SessionActivityTracker
import com.openminis.app.service.SessionConcurrencyManager
import com.openminis.app.ui.chat.ChatViewModelStore
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.util.concurrent.ConcurrentHashMap

/** 删除与启动执行共用的短期门闩，不主动取消正在运行的任务。 */
object SessionDeleteGuard {
    private val deleting = ConcurrentHashMap.newKeySet<String>()

    /** 任务启动前检查，删除中的会话不能重新接受指令。 */
    fun isDeleting(id: String): Boolean = ChatViewModelStore.resolvePersistedId(id) in deleting

    /** 主线程确认执行、准备和排队状态后标记，Tracker占用与此操作串行。 */
    fun begin(context: Context, id: String, forbidden: Set<String>): Boolean = synchronized(SessionActivityTracker) {
        val key = ChatViewModelStore.resolvePersistedId(id)
        if (key.startsWith("__") || key in forbidden || io.github.nanomuse.home.MainChat.isMain(context, key) ||
            SessionActivityTracker.isActive(key) || io.github.nanomuse.routines.ScheduledRunScopes.isActive(key) || key in SessionConcurrencyManager.runningSessions.value ||
            key in SessionConcurrencyManager.suspendedSessions.value || ChatViewModelStore.isSessionBusy(key)) return false
        deleting.add(key)
    }

    /** 成功或失败都清理门闩，失败项可以稍后重试。 */
    fun finish(id: String) { deleting.remove(ChatViewModelStore.resolvePersistedId(id)) }

    /** Mosaic: 命令行删除与侧栏同一套保护：任务目标、隐藏、主聊天和执行中的会话跳过不删。 */
    suspend fun delete(context: Context, repo: com.openminis.app.data.repository.ChatRepository, ids: List<String>): SessionDeleteReport {
        val forbidden = withContext(Dispatchers.IO) {
            com.openminis.app.scheduled.ScheduledTaskStore(context).all().mapNotNull { it.targetMode.sessionIdOrNull }.toSet()
        } + io.github.nanomuse.sync.ConversationSync.hidden.value + io.github.nanomuse.feed.FeedFlow.hidden.value
        val eligible = withContext(Dispatchers.Main) { ids.filter { begin(context, it, forbidden) } }
        try {
            repo.deleteSessions(eligible)
            withContext(Dispatchers.Main) {
                eligible.forEach { id -> runCatching {
                    ChatViewModelStore.release(id)
                    com.openminis.app.debug.HeadlessChatRunner.forget(id)
                    com.openminis.app.service.SessionBadgeStore.clear(id)
                } }
            }
            return SessionDeleteReport(eligible.toSet(), ids.toSet() - eligible.toSet(), emptySet())
        } catch (cancelled: kotlinx.coroutines.CancellationException) { throw cancelled }
        catch (_: Exception) { return SessionDeleteReport(emptySet(), ids.toSet() - eligible.toSet(), eligible.toSet()) }
        finally { eligible.forEach { finish(it) } }
    }
}

/** 批量删除明确区分已完成、保护跳过和失败，不以提前清空选择伪装成功。 */
data class SessionDeleteReport(val deleted: Set<String>, val protectedIds: Set<String>, val failed: Set<String>)
