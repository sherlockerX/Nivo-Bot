package io.github.nanomuse.coach

import android.content.Context
import android.content.ContextWrapper
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.openminis.app.MinisApp
import com.openminis.app.data.db.AppDatabase
import com.openminis.app.data.db.ChatSessionEntity
import com.openminis.app.data.repository.ChatRepository
import io.github.nanomuse.sync.ConversationSync
import io.github.nanomuse.sync.RoomChats
import java.io.File
import java.util.UUID
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/** 只在隔离调试App中执行，教练文件位于每次测试独立目录。 */
@RunWith(AndroidJUnit4::class)
class CoachConversationIntegrationTest {
    private lateinit var app: MinisApp
    private lateinit var context: Context
    private lateinit var directory: File
    private lateinit var repository: ChatRepository
    private lateinit var topic: CoachTopic
    private var createdPracticeGroup = false
    private val createdChats = mutableSetOf<String>()
    private val createdGroups = mutableSetOf<String>()
    private val course = CoachCourse("integration-${UUID.randomUUID()}", "集成验证", "测试",
        CoachKind.EXPRESSION, listOf(CoachUnit("unit", "测试单元", "已有自建案例", "解释",
            listOf(CoachCriterion("understanding", "解释", dimension = "understanding"),
                CoachCriterion("application", "应用", dimension = "application")))), "v1")

    @Before fun setUp() = runBlocking {
        app = ApplicationProvider.getApplicationContext()
        check(app.packageName.endsWith(".uitest")) { "测试只能在隔离.uitest应用运行" }
        directory = File(app.cacheDir, "coach-integration-${UUID.randomUUID()}").apply { mkdirs() }
        context = object : ContextWrapper(app) {
            override fun getFilesDir(): File = directory
            override fun getApplicationContext(): Context = this
        }
        CoachRuntime.reset()
        topic = CoachTopic(UUID.randomUUID().toString(), course.id, "unit", "用户已有案例", "自建案例内容")
        CoachFileStore(File(directory, "minis-global/nanomuse/growth/coach-v2")).save(
            CoachState(tracks = listOf(CoachTrack(course)), topics = listOf(topic), selectedCourseId = course.id))
        repository = ChatRepository(AppDatabase.getInstance(app).chatDao(), context)
        createdPracticeGroup = repository.getFolder(CoachConversationCoordinator.GROUP_ID) == null
    }

    @After fun tearDown(): Unit = runBlocking {
        if (::repository.isInitialized) {
            createdChats.forEach { repository.dao.deleteConversation(it) }
            createdGroups.forEach { repository.dao.deleteFolder(it) }
            if (createdPracticeGroup && repository.sessionIdsInFolder(CoachConversationCoordinator.GROUP_ID).isEmpty()) {
                repository.dao.dissolveFolderAtomic(CoachConversationCoordinator.GROUP_ID)
            }
        }
        CoachRuntime.reset()
        if (::directory.isInitialized) {
            check(directory.canonicalPath.startsWith(app.cacheDir.canonicalPath + File.separator))
            directory.deleteRecursively()
        }
    }

    @Test fun should_resumeInterruptedCreation_withoutDuplicatingTopicOrLesson() = runBlocking {
        val id = seedInterruptedCreation()
        val first = CoachConversationCoordinator.open(context, repository, app.providerRepository, course.id)
        val service = CoachRuntime.service(context)
        val lesson = service.state.value.topics.single().activeSessionId!!
        assertEquals(id, first)
        assertEquals(id, CoachConversationCoordinator.open(context, repository, app.providerRepository, course.id))
        assertEquals(1, service.state.value.topics.size)
        assertEquals(1, service.state.value.sessions.size)
        assertEquals("自建案例内容", service.state.value.topics.single().caseText)
        val result = service.execute(CoachCommand("end_lesson", UUID.randomUUID().toString(),
            service.state.value.revision, lesson))
        assertTrue(result.message, result.success)
        assertEquals(id, CoachConversationCoordinator.open(context, repository, app.providerRepository, course.id))
        assertNotEquals(lesson, service.state.value.topics.single().activeSessionId)
        assertEquals(2, service.state.value.sessions.size)
    }

    @Test fun should_keepExcerptsReadOnly_when_chatIsDeletedBySync() = runBlocking {
        val id = seedInterruptedCreation()
        CoachConversationCoordinator.open(context, repository, app.providerRepository, course.id)
        val service = CoachRuntime.service(context)
        val message = repository.appendMessage(id, "user", "[{\"type\":\"text\",\"value\":\"我的问题\"}]")
        assertTrue(service.registerConversationUser(id, message.id, "我的问题").success)
        withTimeout(5_000) {
            ConversationSync.exclusive { RoomChats(context, repository).deleteSession(id) }
        }
        assertNull(repository.getSession(id))
        assertEquals("archived", service.state.value.topics.single().status)
        assertTrue(service.state.value.sessions.single().turns.single().sourceInvalidated)
    }

    @Test fun should_resumePausedLesson_when_userActivelyReopensResumedCourse() = runBlocking {
        val id = seedInterruptedCreation()
        CoachConversationCoordinator.open(context, repository, app.providerRepository, course.id)
        val service = CoachRuntime.service(context)
        val lesson = service.state.value.sessions.single().id
        listOf("pause_course", "resume_course").forEach { action ->
            val result = service.execute(CoachCommand(action, UUID.randomUUID().toString(),
                service.state.value.revision, course.id))
            assertTrue(result.message, result.success)
        }
        assertEquals("paused", service.state.value.sessions.single().status)
        assertEquals(id, CoachConversationCoordinator.open(context, repository, app.providerRepository, course.id))
        assertEquals(lesson, service.state.value.sessions.single().id)
        assertEquals("active", service.state.value.sessions.single().status)
    }

    @Test fun should_preserveIdenticalAppend_andInvalidateChangedOrDeletedSource() = runBlocking {
        val id = seedInterruptedCreation()
        CoachConversationCoordinator.open(context, repository, app.providerRepository, course.id)
        val service = CoachRuntime.service(context)
        val parts = "[{\"type\":\"text\",\"value\":\"原回答\"}]"
        val message = repository.appendMessage(id, "user", parts)
        assertTrue(service.registerConversationUser(id, message.id, "原回答").success)
        repository.appendMessage(id, "user", parts, messageId = message.id)
        assertFalse(service.state.value.sessions.single().turns.single().sourceInvalidated)
        repository.updateMessageParts(message.id, "[{\"type\":\"text\",\"value\":\"更正\"}]")
        assertTrue(service.state.value.sessions.single().turns.single().sourceInvalidated)
    }

    @Test fun should_resumeConfirmedPurge_afterRepositoryIsRecreated() = runBlocking {
        val id = seedInterruptedCreation()
        CoachConversationCoordinator.open(context, repository, app.providerRepository, course.id)
        repository.prepareCoachDeletion(setOf(id), shouldPurge = true)
        repository.deleteSession(id)
        assertTrue(CoachRuntime.service(context).state.value.topics.isNotEmpty())
        val restarted = ChatRepository(repository.dao, context)
        restarted.recoverCoachDeletions()
        assertTrue(CoachRuntime.service(context).state.value.topics.isEmpty())
        assertTrue(CoachRuntime.service(context).state.value.sessions.isEmpty())
        assertNull(restarted.getSession(id))
    }

    @Test fun should_cancelUnexecutedPurge_afterRestartWithChatStillPresent() = runBlocking {
        val id = seedInterruptedCreation()
        CoachConversationCoordinator.open(context, repository, app.providerRepository, course.id)
        repository.prepareCoachDeletion(setOf(id), shouldPurge = true)
        val restarted = ChatRepository(repository.dao, context)
        restarted.recoverCoachDeletions()
        restarted.deleteSession(id)
        restarted.recoverCoachDeletions()
        assertEquals("archived", CoachRuntime.service(context).state.value.topics.single().status)
    }

    @Test fun should_invalidateMissingBoundChat_insteadOfRecreatingIt() = runBlocking {
        val id = seedInterruptedCreation()
        CoachConversationCoordinator.open(context, repository, app.providerRepository, course.id)
        repository.dao.deleteConversation(id)
        assertTrue(runCatching {
            CoachConversationCoordinator.open(context, repository, app.providerRepository, course.id)
        }.isFailure)
        assertNull(repository.getSession(id))
        assertEquals("archived", CoachRuntime.service(context).state.value.topics.single().status)
    }

    @Test fun should_keepUserNamedGroup_andCreateTopicWithDeterministicId() = runBlocking {
        org.junit.Assume.assumeTrue(repository.getFolder(CoachConversationCoordinator.GROUP_ID) == null)
        val displayName = context.getString(com.openminis.app.R.string.nm_coach_conversation_group)
        val userGroup = repository.findFolderByName(displayName) ?: repository.createFolder(displayName)
            .also { createdGroups.add(it.id) }
        org.junit.Assume.assumeTrue(app.providerRepository.allVisibleEntries().isNotEmpty())
        val id = CoachConversationCoordinator.conversationId(topic.id)
        createdChats.add(id)
        assertEquals(id, CoachConversationCoordinator.open(context, repository, app.providerRepository, course.id))
        val practice = repository.getFolder(CoachConversationCoordinator.GROUP_ID)!!
        assertNotEquals(userGroup.id, practice.id)
        assertNotEquals(userGroup.name, practice.name)
        assertEquals(userGroup, repository.getFolder(userGroup.id))
        assertEquals(practice.id, repository.getSession(id)!!.folderId)
    }

    @Test fun should_clearSpecificSyncSource_withoutReenteringAccountLock() = runBlocking {
        val id = seedInterruptedCreation()
        CoachConversationCoordinator.open(context, repository, app.providerRepository, course.id)
        val service = CoachRuntime.service(context)
        val message = repository.appendMessage(id, "user", "[{\"type\":\"text\",\"value\":\"同步删除\"}]")
        assertTrue(service.registerConversationUser(id, message.id, "同步删除").success)
        withTimeout(5_000) {
            ConversationSync.exclusive { RoomChats(context, repository).deleteMessage(message.id) }
        }
        assertNull(repository.dao.findMessage(message.id))
        assertTrue(service.state.value.sessions.single().turns.single().sourceInvalidated)
    }

    @Test fun should_stageExplicitFinalText_beforePersistingTheMessage() = runBlocking {
        val id = seedInterruptedCreation()
        CoachConversationCoordinator.open(context, repository, app.providerRepository, course.id)
        val message = repository.appendMessage(id, "assistant", "[{\"type\":\"text\",\"value\":\"最终正文\"}]",
            coachArchiveText = "最终正文")
        val store = CoachArchiveOutbox(File(directory, "minis-global/nanomuse/growth/coach-v2/archive-outbox"))
        assertTrue(store.read(id).entries.any { it.messageId == message.id && it.text == "最终正文" })
        assertNull(CoachConversationArchive.retry(context, repository, id))
        assertTrue(store.read(id).entries.isEmpty())
        assertEquals(message.id, CoachRuntime.service(context).state.value.sessions.single().turns.single().originMessageId)
    }

    private suspend fun seedInterruptedCreation(): String {
        val id = CoachConversationCoordinator.conversationId(topic.id)
        createdChats.add(id)
        repository.dao.insertSession(ChatSessionEntity(id = id, title = topic.title,
            modelId = "test-model", createdAt = 1, updatedAt = 1,
            source = CoachConversationCoordinator.SESSION_SOURCE))
        return id
    }
}
