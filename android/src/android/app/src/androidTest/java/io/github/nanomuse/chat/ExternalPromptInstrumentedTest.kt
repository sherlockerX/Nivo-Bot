package io.github.nanomuse.chat

import androidx.lifecycle.ViewModelProvider
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.openminis.app.MinisApp
import com.openminis.app.data.db.MessageEntity
import com.openminis.app.data.repository.MemoryRepository
import com.openminis.app.ui.chat.ChatViewModel
import com.openminis.app.ui.chat.ChatViewModelStore
import com.openminis.app.ui.chat.InputAttachment
import com.openminis.app.ui.chat.PastedText
import io.github.nanomuse.sync.SyncDatabase
import java.io.File
import java.nio.file.Files
import java.util.UUID
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/** nanoMuse: 使用隔离包的真实VM与Room验证外部预填，不发送请求或调用模型。 */
@RunWith(AndroidJUnit4::class)
class ExternalPromptInstrumentedTest {
    /** 空输入接收外部模板并发出聚焦事件，不写入聊天历史。 */
    @Test
    fun should_fillAndFocus_when_composerIsEmpty() = runBlocking {
        withFixture { fixture ->
            val before = composerState(fixture.vm)
            assertEquals(ComposerState("", null, emptyList(), emptyList()), before)
            expectFocus(fixture.vm) { fixture.vm.nmPrefillComposer("外部模板") }
            assertEquals(before.copy(inputText = "外部模板"), composerState(fixture.vm))
            assertHistoryUnchangedAndIdle(fixture)
        }
    }

    /** 普通草稿和纯空白草稿都必须原样保留，不能被外部模板替换。 */
    @Test
    fun should_keepDraftAndFocus_when_textOrWhitespaceExists() = runBlocking {
        for (draft in listOf("已有草稿\n保留末尾空格 ", " \n\t")) {
            withFixture { fixture ->
                withContext(Dispatchers.Main) { fixture.vm.setInputText(draft) }
                val before = composerState(fixture.vm)
                expectFocus(fixture.vm) { fixture.vm.nmPrefillComposer("不可覆盖的外部模板") }
                assertEquals(before, composerState(fixture.vm))
                assertHistoryUnchangedAndIdle(fixture)
            }
        }
    }

    /** 即使输入文字为空，旧消息编辑目标也必须保留，后续Room历史不得截断。 */
    @Test
    fun should_keepEditTargetAndHistory_when_onlyEditingTargetExists() = runBlocking {
        withFixture(hasHistory = true) { fixture ->
            val editedId = fixture.history.first().id
            withContext(Dispatchers.Main) {
                assertNotNull(fixture.vm.editMessage(editedId))
            }
            val before = composerState(fixture.vm)
            assertEquals(ComposerState("", editedId, emptyList(), emptyList()), before)
            expectFocus(fixture.vm) { fixture.vm.nmPrefillComposer("外部模板") }
            assertEquals(before, composerState(fixture.vm))
            assertHistoryUnchangedAndIdle(fixture)
        }
    }

    /** 仅文档附件也占用输入，预填不得清除附件或修改实际文件。 */
    @Test
    fun should_keepDocumentAndFocus_when_onlyAttachmentExists() = runBlocking {
        withFixture { fixture ->
            val document = addDocument(fixture)
            val before = composerState(fixture.vm)
            assertEquals("", before.inputText)
            assertEquals(listOf(document), before.attachments)
            assertEquals(InputAttachment.Kind.DOCUMENT, document.kind)
            assertEquals(emptyList<PastedText>(), before.pastedTexts)
            expectFocus(fixture.vm) { fixture.vm.nmPrefillComposer("外部模板") }
            assertEquals(before, composerState(fixture.vm))
            assertEquals(DOCUMENT_TEXT, File(requireNotNull(document.uri.path)).readText())
            assertHistoryUnchangedAndIdle(fixture)
        }
    }

    /** 粘贴缓存可独立于输入框存在，外部预填仍必须保留其身份和内容。 */
    @Test
    fun should_keepPasteAndFocus_when_onlyPastedTextExists() = runBlocking {
        withFixture { fixture ->
            withContext(Dispatchers.Main) { fixture.vm.stashPastedText("尚未发送的粘贴内容") }
            val before = composerState(fixture.vm)
            assertEquals("", before.inputText)
            assertEquals(emptyList<InputAttachment>(), before.attachments)
            assertEquals("尚未发送的粘贴内容", before.pastedTexts.single().text)
            expectFocus(fixture.vm) { fixture.vm.nmPrefillComposer("外部模板") }
            assertEquals(before, composerState(fixture.vm))
            assertHistoryUnchangedAndIdle(fixture)
        }
    }

    /** 聊天内明确追加只改变文字，编辑目标、附件、粘贴缓存及历史全部保留。 */
    @Test
    fun should_appendIdeaAndFocus_when_userExplicitlyAppends() = runBlocking {
        withFixture { fixture ->
            expectFocus(fixture.vm) { fixture.vm.nmAppendComposerIdea("空输入点子") }
            assertEquals("空输入点子", composerState(fixture.vm).inputText)
            assertHistoryUnchangedAndIdle(fixture)
        }
        withFixture(hasHistory = true) { fixture ->
            withContext(Dispatchers.Main) {
                assertNotNull(fixture.vm.editMessage(fixture.history.first().id))
                fixture.vm.setInputText("正在编辑的草稿 ")
                fixture.vm.stashPastedText("追加前已有粘贴")
            }
            val document = addDocument(fixture)
            val before = composerState(fixture.vm)
            assertEquals(fixture.history.first().id, before.editingMessageId)
            assertEquals(listOf(document), before.attachments)
            assertEquals(1, before.pastedTexts.size)
            expectFocus(fixture.vm) { fixture.vm.nmAppendComposerIdea("追加点子") }
            assertEquals(before.copy(inputText = before.inputText + "\n\n追加点子"),
                composerState(fixture.vm))
            assertEquals(DOCUMENT_TEXT, File(requireNotNull(document.uri.path)).readText())
            assertHistoryUnchangedAndIdle(fixture)
        }
    }

    /** 每例仅持有自身会话、历史快照、临时目录和经真实附件入口创建的副本。 */
    private data class Fixture(
        val app: MinisApp,
        val sessionId: String,
        val vm: ChatViewModel,
        val history: List<MessageEntity>,
        val directory: File,
        val copiedDocuments: MutableList<File>,
    )

    /** 输入快照同时比较各状态，防止测试只关注文字而漏掉附件或编辑目标。 */
    private data class ComposerState(
        val inputText: String,
        val editingMessageId: String?,
        val attachments: List<InputAttachment>,
        val pastedTexts: List<PastedText>,
    )

    private suspend fun withFixture(
        hasHistory: Boolean = false,
        verify: suspend (Fixture) -> Unit,
    ) {
        val app = ApplicationProvider.getApplicationContext<MinisApp>()
        check(app.packageName.endsWith(".uitest")) { "只允许隔离测试包" }
        val directory = Files.createTempDirectory(app.cacheDir.toPath(), "external-prompt-").toFile()
        val copiedDocuments = mutableListOf<File>()
        var sessionId: String? = null
        try {
            val session = app.chatRepository.createSession(
                "fixture-${UUID.randomUUID()}", memoryEnabled = true,
            )
            sessionId = session.id
            if (hasHistory) seedHistory(app, session.id)
            val history = app.chatRepository.loadMessages(session.id)
            val vm = withContext(Dispatchers.Main) {
                ViewModelProvider(ChatViewModelStore.ownerFor(session.id), ChatViewModel.factory(
                    sessionId = session.id, chatRepository = app.chatRepository,
                    providerRepository = app.providerRepository, appContext = app,
                    memoryRepository = MemoryRepository(directory),
                    skillRepository = null, mcpRepository = null,
                ))[ChatViewModel::class.java].also {
                    withTimeout(10_000) { it.nmAwaitSessionReady() }
                }
            }
            val fixture = Fixture(app, session.id, vm, history, directory, copiedDocuments)
            assertHistoryUnchangedAndIdle(fixture)
            verify(fixture)
        } finally {
            // 断言失败和协程取消也执行清理，不删除其他会话或共享缓存目录。
            withContext(NonCancellable) {
                try { sessionId?.let { cleanupSession(app, it) } }
                finally { cleanupFiles(app, directory, copiedDocuments) }
            }
        }
    }

    private suspend fun seedHistory(app: MinisApp, sessionId: String) {
        for ((role, text) in listOf("user" to "原始问题", "assistant" to "原始回答",
                "user" to "后续问题", "assistant" to "必须保留的后续回答")) {
            val parts = JSONArray().put(JSONObject().put("type", "text").put("value", text))
            app.chatRepository.appendMessage(sessionId, role, parts.toString())
        }
    }

    private suspend fun composerState(vm: ChatViewModel): ComposerState =
        withContext(Dispatchers.Main) {
            ComposerState(vm.inputText.value, vm.editingMessageId.value,
                vm.attachments.value.toList(), vm.pastedTexts.value.toList())
        }

    private suspend fun expectFocus(vm: ChatViewModel, action: () -> Unit) {
        withContext(Dispatchers.Main) {
            coroutineScope {
                // SharedFlow不重放，必须在调用入口前完成订阅，避免假超时。
                val focused = async(start = CoroutineStart.UNDISPATCHED) {
                    withTimeout(5_000) { vm.nmFocusComposer.first() }
                }
                try { action(); focused.await() }
                finally { focused.cancel() }
            }
        }
    }

    private suspend fun addDocument(fixture: Fixture): InputAttachment {
        val source = File(fixture.directory, "fixture-document.txt")
        source.writeText(DOCUMENT_TEXT)
        return withContext(Dispatchers.Main) {
            val attachment = requireNotNull(fixture.vm.addAttachmentFromStagedShare(source))
            fixture.copiedDocuments.add(File(requireNotNull(attachment.uri.path)))
            attachment
        }
    }

    private suspend fun assertHistoryUnchangedAndIdle(fixture: Fixture) {
        assertEquals(fixture.history, fixture.app.chatRepository.loadMessages(fixture.sessionId))
        withContext(Dispatchers.Main) {
            assertFalse(fixture.vm.isStreaming.value)
            assertTrue(fixture.vm.promptQueue.value.isEmpty())
            assertTrue(fixture.vm.streamingById.value.isEmpty())
            val persistedIds = fixture.history.map { it.id }.toSet()
            assertEquals(fixture.history.map { it.id },
                fixture.vm.messages.value.filter { it.id in persistedIds }.map { it.id })
        }
    }

    private suspend fun cleanupSession(app: MinisApp, sessionId: String) {
        try { withContext(Dispatchers.Main) { ChatViewModelStore.release(sessionId) } }
        finally {
            try { app.chatRepository.dao.deleteConversation(sessionId) }
            finally { SyncDatabase.get(app).dao().removeOwners(listOf(sessionId)) }
        }
    }

    private fun cleanupFiles(app: MinisApp, directory: File, copiedDocuments: List<File>) {
        val cacheRoot = app.cacheDir.canonicalFile
        val fixtureRoot = directory.canonicalFile
        check(fixtureRoot.parentFile == cacheRoot && fixtureRoot.name.startsWith("external-prompt-"))
        val shareRoot = File(cacheRoot, "share_inbound").canonicalFile
        try {
            for (document in copiedDocuments) {
                check(document.canonicalFile.parentFile == shareRoot)
                check(!document.exists() || document.delete()) { "测试文档副本清理失败" }
            }
        } finally {
            check(!fixtureRoot.exists() || fixtureRoot.deleteRecursively()) { "测试临时目录清理失败" }
        }
    }

    private companion object {
        const val DOCUMENT_TEXT = "测试文档：保留完整内容，不发送给模型。\n"
    }
}
