package io.github.nanomuse.coach

import android.content.Context
import com.openminis.app.data.db.MessageEntity
import com.openminis.app.data.repository.ChatRepository
import io.github.nanomuse.account.AccountData
import io.github.nanomuse.sync.ConversationSync
import io.github.nanomuse.sync.SyncDatabase
import java.io.File
import java.security.MessageDigest
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/** 真实聊天消息是归档来源；账户切换和来源删除与整理操作共用互斥锁。 */
object CoachConversationArchive {
    private fun outbox(context: Context) = CoachArchiveOutbox(
        File(context.filesDir, "minis-global/nanomuse/growth/coach-v2/archive-outbox"))

    /** 调用方必须已持账户锁；数据库插入前固定原文、课次与所有者，失败直接抛出。 */
    fun stage(context: Context, message: MessageEntity, text: String) {
        val owner = AccountData.key(context)
        val epoch = CoachRuntime.epoch.value
        val service = CoachRuntime.service(context)
        val topic = service.topicForConversation(message.sessionId)?.takeIf { it.status == "active" } ?: return
        require(message.role in setOf("user", "assistant")) { "Unsupported archive message role" }
        check(message.sessionId !in ConversationSync.hidden.value) { "This conversation belongs to another account" }
        val archived = archivedTurns(service.state.value, topic.id, message.id, message.role)
        if (archived.isNotEmpty()) {
            require(archived.any { it.text == text } && archived.none { it.sourceInvalidated }) {
                "The original archived message changed; invalidate its source first"
            }
            checkAccount(context, owner, epoch)
            return
        }
        val lessonId = topic.activeSessionId ?: service.state.value.sessions.lastOrNull {
            it.topicId == topic.id }?.id ?: error("Start a topic lesson before archiving its messages")
        checkAccount(context, owner, epoch)
        outbox(context).put(CoachArchiveEntry(message.sessionId, message.id, lessonId,
            message.role, text, hash(message.partsJson), message.sortOrder, owner))
    }

    /** 兼容已落盘消息；首次stage的原文和课次是权威值，成功后仍报告所有剩余待办。 */
    suspend fun save(context: Context, repo: ChatRepository, chatId: String, messageId: String,
        role: String, text: String): String? {
        val owner = AccountData.key(context)
        val epoch = CoachRuntime.epoch.value
        return withContext(Dispatchers.IO) {
            archiveResult {
                ConversationSync.exclusive {
                    checkAccount(context, owner, epoch)
                    requireOwner(context, chatId, owner)
                    val stagingError = archiveAttempt {
                        val source = repo.dao.findMessage(messageId) ?: error("原消息尚未保存")
                        require(source.sessionId == chatId && source.role.equals(role, true)) {
                            "Archive source identity does not match the message"
                        }
                        stageSavedSource(context, source, text, owner)
                    }
                    combineErrors(listOfNotNull(stagingError, retryLocked(context, repo, chatId)))
                }
            }
        }
    }

    /** 页面恢复和手动重试先取得账户互斥锁，等待期间切换账号会明确拒绝旧请求。 */
    suspend fun retry(context: Context, repo: ChatRepository, chatId: String): String? {
        val owner = AccountData.key(context)
        val epoch = CoachRuntime.epoch.value
        return withContext(Dispatchers.IO) {
            archiveResult {
                ConversationSync.exclusive {
                    checkAccount(context, owner, epoch)
                    retryLocked(context, repo, chatId)
                }
            }
        }
    }

    /** 调用方已持账户锁时使用；逐项整理，某一损坏或失败项不阻塞其他待办。 */
    suspend fun retryLocked(context: Context, repo: ChatRepository, chatId: String): String? = archiveResult {
        val owner = AccountData.key(context)
        val epoch = CoachRuntime.epoch.value
        requireOwner(context, chatId, owner)
        val service = CoachRuntime.service(context)
        val store = outbox(context)
        val snapshot = store.read(chatId)
        val errors = snapshot.errors.toMutableList()
        snapshot.entries.forEach { entry ->
            val failure = archiveAttempt {
                checkAccount(context, owner, epoch)
                apply(context, repo, service, store, entry, owner, epoch)
            }
            if (failure != null) errors += "${entry.messageId}: $failure"
        }
        // 再读一次确认全部待办；不能因最后一条成功就清除前面的失败提示。
        val remaining = store.read(chatId)
        errors += remaining.errors
        if (remaining.entries.isNotEmpty() && errors.isEmpty()) errors += "仍有消息等待整理"
        combineErrors(errors)
    }

    /** VM的缩略显示可能与入队文字不同，已经stage的真实来源始终优先。 */
    private fun stageSavedSource(context: Context, source: MessageEntity, text: String, owner: String) {
        val original = outbox(context).read(source.sessionId).entries.firstOrNull { it.messageId == source.id }
        if (original != null) {
            require(original.owner == owner && original.sourceHash == hash(source.partsJson) &&
                original.role.equals(source.role, true)) { "The staged archive source changed" }
            return
        }
        val state = CoachRuntime.service(context).state.value
        val topic = state.topics.singleOrNull { it.chatSessionId == source.sessionId } ?: return
        // 待办可能已被恢复任务提交；再次保存不能把旧来源移到现在的新课次。
        val archived = archivedTurns(state, topic.id, source.id, source.role)
        if (archived.isNotEmpty()) {
            require(archived.none { it.sourceInvalidated }) { "The archived source was invalidated" }
            return
        }
        stage(context, source, text)
    }

    private fun archivedTurns(state: CoachState, topicId: String, messageId: String, role: String): List<CoachTurn> {
        val archiveRole = if (role == "assistant") "coach" else role
        return state.sessions.filter { it.topicId == topicId }.flatMap { session ->
            session.turns.filter { it.originMessageId == messageId && it.role == archiveRole }
        }
    }

    private suspend fun apply(context: Context, repo: ChatRepository, service: CoachCommandService,
        store: CoachArchiveOutbox, entry: CoachArchiveEntry, owner: String, epoch: Long) {
        require(entry.owner == owner) { "The archive retry record belongs to another account" }
        val source = repo.dao.findMessage(entry.messageId)
        checkAccount(context, owner, epoch)
        val topic = service.topicForConversation(entry.chatId)
        if (source == null || topic == null || topic.status != "active" || source.sessionId != entry.chatId ||
            !source.role.equals(entry.role, true) || hash(source.partsJson) != entry.sourceHash || entry.text.isBlank()) {
            // stage之后插入失败留下的孤儿，或已删除/变更的源，都不得重建原文副本；
            // 旧版本为只有图片的消息留下的空原文永远无法保存，同样移除，免得一直卡住专题。
            store.remove(entry.chatId, entry.messageId)
            return
        }
        val result = if (entry.role == "user") service.registerConversationUser(
            entry.chatId, entry.messageId, entry.text, expectedSessionId = entry.lessonId)
        else service.recordConversationReply(entry.chatId, entry.messageId, entry.text, expectedSessionId = entry.lessonId)
        check(result.success) { result.message }
        store.remove(entry.chatId, entry.messageId)
    }

    /** 删除调用方已持账户锁，此处只清除目标待办，绝不重入exclusive。 */
    fun forget(context: Context, chatId: String, messageId: String? = null) {
        outbox(context).forget(chatId, messageId)
    }

    private suspend fun requireOwner(context: Context, chatId: String, owner: String) {
        check(chatId !in ConversationSync.hidden.value) { "This conversation belongs to another account" }
        val stored = SyncDatabase.get(context).dao().owners().firstOrNull { it.sessionId == chatId }
        require(stored == null || stored.owner == owner) { "This conversation belongs to another account" }
    }

    private fun checkAccount(context: Context, owner: String, epoch: Long) {
        check(AccountData.key(context) == owner && CoachRuntime.epoch.value == epoch) {
            "账户已切换，请重新打开当前聊天"
        }
    }

    private fun hash(text: String): String = MessageDigest.getInstance("SHA-256")
        .digest(text.toByteArray(Charsets.UTF_8)).joinToString("") { "%02x".format(it) }

    private fun combineErrors(errors: List<String>): String? = errors.distinct().joinToString("\n").ifBlank { null }

    private suspend fun archiveAttempt(block: suspend () -> Unit): String? = archiveResult { block(); null }

    private suspend fun archiveResult(block: suspend () -> String?): String? = try {
        block()
    } catch (cancelled: CancellationException) {
        throw cancelled
    } catch (failure: Exception) {
        failure.message ?: "档案整理失败"
    }
}
