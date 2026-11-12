package io.github.nanomuse.coach

import android.content.Context
import androidx.room.withTransaction
import com.openminis.app.R
import com.openminis.app.data.MemoryGlobalPrefs
import com.openminis.app.data.db.AppDatabase
import com.openminis.app.data.db.ChatSessionEntity
import com.openminis.app.data.db.FolderEntity
import com.openminis.app.data.repository.ChatRepository
import com.openminis.app.data.repository.ProviderRepository
import io.github.nanomuse.account.AccountData
import io.github.nanomuse.chat.GroupNamePolicy
import io.github.nanomuse.chat.SessionDeleteGuard
import io.github.nanomuse.sync.ConversationSync
import io.github.nanomuse.sync.SyncDatabase
import java.util.UUID
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import org.json.JSONObject

/** 专题、会话和课次的可恢复入口；导航与首次教学发送由界面宿主负责。 */
object CoachConversationCoordinator {
    const val GROUP_ID = "daily-practice"
    const val SESSION_SOURCE = "coach_practice"
    private val opening = Mutex()

    /** 主动打开课程时建立或复用专题聊天，并开始或恢复课次。 */
    suspend fun open(context: Context, repo: ChatRepository, providers: ProviderRepository,
        courseId: String): String = withContext(Dispatchers.IO) {
        opening.withLock {
            ConversationSync.exclusive {
                openInAccount(context.applicationContext, repo, providers, courseId)
            }
        }
    }

    private suspend fun openInAccount(context: Context, repo: ChatRepository,
        providers: ProviderRepository, courseId: String): String {
        repo.attachCoachContext(context)
        val owner = AccountData.key(context)
        val epoch = CoachRuntime.epoch.value
        repo.recoverCoachDeletionsLocked()
        val service = CoachRuntime.service(context)
        val topic = selectTopic(service, courseId)
        val chatId = topic.chatSessionId.ifBlank { conversationId(topic.id) }
        requireVisible(chatId)
        requireAccount(context, owner, epoch)
        val existing = repo.getSession(chatId)
        if (topic.chatSessionId.isNotBlank() && existing == null) {
            checked(service.invalidateConversation(chatId, "conversation_deleted"))
            error("This topic conversation was deleted. Open the course again to start a new topic.")
        }
        requireOwner(context, chatId, owner)
        if (existing == null) createConversation(context, repo, providers, topic, chatId, owner, epoch)
        else if (topic.chatSessionId.isBlank()) {
            require(existing.source == SESSION_SOURCE && existing.id == conversationId(topic.id)) {
                "The conversation identity is already in use"
            }
        }
        if (existing != null) ensurePracticeFolder(context, repo, chatId, owner, epoch)
        requireAccount(context, owner, epoch)
        requireVisible(chatId)
        checked(service.bindTopicConversation(topic.id, chatId))
        val currentLesson = topic.activeSessionId?.let { id -> service.state.value.sessions.find { it.id == id } }
        // 课程改版后锁定的旧课只供回看，恢复会被拒绝并卡住专题；交给 start_lesson 按新标准开始新课。
        if (currentLesson?.status == "paused" && !currentLesson.requiresCourseReview &&
            currentLesson.course.version == service.state.value.tracks.find { it.course.id == currentLesson.course.id }?.course?.version) {
            execute(service, "resume_session", currentLesson.id)
        }
        CoachConversationArchive.retryLocked(context, repo, chatId)?.let { error(it) }
        val lessonId = execute(service, "start_lesson", topic.id)
        if (service.state.value.sessions.single { it.id == lessonId }.status == "paused") {
            execute(service, "resume_session", lessonId)
        }
        return chatId
    }

    private suspend fun ensurePracticeFolder(context: Context, repo: ChatRepository,
        chatId: String, owner: String, epoch: Long) {
        AppDatabase.getInstance(context).withTransaction {
            requireAccount(context, owner, epoch)
            requireVisible(chatId)
            val folder = practiceFolder(context, repo, System.currentTimeMillis())
            if (repo.getFolder(folder.id) == null) repo.dao.insertFolder(folder)
            // 用户手动移动仍保持专题身份；只修复未分组或已失效的系统分组。
            val session = repo.getSession(chatId) ?: error("The topic conversation was deleted")
            if (session.folderId == null && session.groupAssignedBy != "user") {
                repo.dao.setSessionFolder(chatId, folder.id)
            }
        }
    }

    private fun selectTopic(service: CoachCommandService, courseId: String): CoachTopic {
        val state = service.state.value
        val track = state.tracks.singleOrNull { it.course.id == courseId } ?: error("Course not found")
        require(!track.paused) { "Resume this course before opening its topic" }
        require(!track.course.needsCriteriaReview && track.course.units.none { it.needsCriteriaReview }) {
            "Review the course criteria before opening its topic"
        }
        state.topics.lastOrNull { it.courseId == courseId && it.unitId == track.currentUnitId &&
            it.status == "active" }?.let { return it }
        val id = execute(service, "start_topic", courseId)
        return service.state.value.topics.single { it.id == id }
    }

    private suspend fun createConversation(context: Context, repo: ChatRepository,
        providers: ProviderRepository, topic: CoachTopic, chatId: String, owner: String, epoch: Long) {
        val defaultGroupId = providers.defaultPrimaryGroupId
        val modelId = defaultGroupId?.let(providers::group)
            ?.let { providers.availableMemberEntries(it).firstOrNull()?.model?.id }
            ?: providers.allVisibleEntries().firstOrNull()?.baseModel?.id
            ?: error("Configure an available model before starting teaching")
        val now = System.currentTimeMillis()
        val session = ChatSessionEntity(id = chatId, title = topic.title, modelId = modelId,
            createdAt = now, updatedAt = now, source = SESSION_SOURCE, folderId = GROUP_ID,
            groupAssignedBy = "system", memoryEnabled = if (MemoryGlobalPrefs.isGlobalEnabled(context)) 1 else 0,
            modelBinding = defaultGroupId?.let { JSONObject().put("type", "group").put("groupId", it).toString() })
        // 所有权先写入，账号互斥期间不会被另一账户认领；崩溃后可按专题确定性重试。
        AccountData.claimNow(context, chatId, owner)
        requireAccount(context, owner, epoch)
        AppDatabase.getInstance(context).withTransaction {
            requireVisible(chatId)
            requireAccount(context, owner, epoch)
            if (repo.dao.getSession(chatId) == null) {
                val folder = practiceFolder(context, repo, now)
                repo.dao.insertSessionWithFolder(session, folder)
            }
        }
    }

    private suspend fun practiceFolder(context: Context, repo: ChatRepository, now: Long): FolderEntity {
        repo.getFolder(GROUP_ID)?.let { existing ->
            require(existing.origin == SESSION_SOURCE) { "The Daily practice group identity is already in use" }
            return existing
        }
        val base = context.getString(R.string.nm_coach_conversation_group)
        var name = base
        var number = 2
        // 同名用户组保留原身份，新系统组只使用未占用的显示名。
        while (repo.findFolderByName(name) != null) name = GroupNamePolicy.numbered(base, number++)
        return FolderEntity(id = GROUP_ID, name = name, origin = SESSION_SOURCE,
            createdAt = now, updatedAt = now)
    }

    private suspend fun requireOwner(context: Context, chatId: String, owner: String) {
        val stored = SyncDatabase.get(context).dao().owners().firstOrNull { it.sessionId == chatId }
        require(stored == null || stored.owner == owner) { "This conversation belongs to another account" }
    }

    private fun requireVisible(chatId: String) {
        require(chatId !in ConversationSync.hidden.value && !SessionDeleteGuard.isDeleting(chatId)) {
            "This conversation is unavailable or being deleted"
        }
    }

    private fun requireAccount(context: Context, owner: String, epoch: Long) {
        check(AccountData.key(context) == owner && CoachRuntime.epoch.value == epoch) {
            "The account changed; reopen the current course"
        }
    }

    private fun execute(service: CoachCommandService, action: String, targetId: String): String =
        checked(service.execute(CoachCommand(action, "host-open:${UUID.randomUUID()}",
            service.state.value.revision, targetId)))

    private fun checked(result: CoachResult): String {
        check(result.success) { result.message }
        return result.targetId
    }

    /** 稳定会话身份只由可信专题ID派生，崩溃重试不会生成第二条会话。 */
    fun conversationId(topicId: String): String =
        UUID.nameUUIDFromBytes("coach-topic:$topicId".toByteArray(Charsets.UTF_8)).toString()
}
