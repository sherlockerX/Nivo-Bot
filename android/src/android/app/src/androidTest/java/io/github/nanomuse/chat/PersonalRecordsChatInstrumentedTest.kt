package io.github.nanomuse.chat

import android.content.Context
import android.view.accessibility.AccessibilityNodeInfo
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import androidx.room.withTransaction
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.openminis.app.MainActivity
import com.openminis.app.MinisApp
import com.openminis.app.R
import com.openminis.app.data.db.ChatDao
import com.openminis.app.data.db.MessageEntity
import com.openminis.app.data.model.LLMModel
import com.openminis.app.data.model.ModelEntry
import com.openminis.app.data.model.ModelGroup
import com.openminis.app.data.model.ProviderCredential
import com.openminis.app.data.model.ProviderInstance
import com.openminis.app.data.model.ProviderType
import com.openminis.app.data.repository.ChatRepository
import com.openminis.app.debug.HeadlessChatRunner
import com.openminis.app.ui.chat.ChatViewModel
import com.openminis.app.ui.chat.ChatViewModelStore
import io.github.nanomuse.focus.FocusSession
import io.github.nanomuse.focus.FocusStore
import io.github.nanomuse.home.MainChat
import io.github.nanomuse.sync.SyncDatabase
import java.util.UUID
import java.io.File
import java.lang.reflect.InvocationTargetException
import java.lang.reflect.Proxy
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.coroutines.Continuation
import kotlin.coroutines.intrinsics.COROUTINE_SUSPENDED
import kotlin.coroutines.startCoroutine
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import org.json.JSONObject
import org.json.JSONArray
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TestName
import org.junit.runner.RunWith

/** nanoMuse: 通过前台Activity中的正常VM发送入口验证实际请求、授权与Room工具结果。 */
@RunWith(AndroidJUnit4::class)
class PersonalRecordsChatInstrumentedTest {
    @get:Rule val testName = TestName()
    private lateinit var app: MinisApp
    private lateinit var server: PersonalRecordsLoopbackProvider
    private lateinit var scenario: ActivityScenario<MainActivity>
    private lateinit var vm: ChatViewModel
    private lateinit var store: FocusStore
    private lateinit var focus: FocusSession
    private lateinit var entry: ModelEntry
    private lateinit var evidenceFile: File
    private var chatId: String? = null
    private var instanceId: String? = null
    private var originalDefault: String? = null
    private var originalSubDefault: String? = null
    private var originalLastUsed: String? = null
    private var originalEmptyGroups: List<ModelGroup> = emptyList()
    private var hasCapturedDefaults = false
    private var hasCapturedFeed = false
    private var hadFirstDay = false
    private var originalFirstDay = false
    private var hadSetup = false
    private var originalSetup = false

    /** 只追加唯一回环提供商、普通会话和已结束专注，绝不替换正式库或真实授权。 */
    @Before fun prepare() = runBlocking {
        app = ApplicationProvider.getApplicationContext()
        check(app.packageName.endsWith(".uitest")) { "只允许隔离.uitest包" }
        withTimeout(15_000) {
            while (!app.subsystemsReady()) delay(50)
            app.providerRepository.awaitConfigLoaded()
        }
        captureConfiguration()
        val evidenceDirectory = File(app.filesDir, "personal-records-chat-evidence")
        check(evidenceDirectory.isDirectory || evidenceDirectory.mkdirs())
        evidenceFile = File(evidenceDirectory, "${testName.methodName}-${UUID.randomUUID()}.jsonl")
        server = PersonalRecordsLoopbackProvider(evidenceFile)
        addProvider()
        scenario = ActivityScenario.launch(MainActivity::class.java)
        withTimeout(15_000) {
            MainChat.sessionId.first { it != null }
        }
        scenario.onActivity { assertTrue(app.isAppForeground()) }
        val session = app.chatRepository.createSession(entry.model.id,
            "普通聊天工具集成夹具", memoryEnabled = false)
        chatId = session.id
        assertFalse("必须是普通聊天，不能借用主要聊天权限", MainChat.isMain(app, session.id))
        app.chatRepository.updateSessionBinding(session.id,
            JSONObject().put("type", "entry").put("entryId", entry.id).toString(), entry.model.id)
        vm = withContext(Dispatchers.Main) {
            ViewModelProvider(ChatViewModelStore.ownerFor(session.id), ChatViewModel.factory(
                sessionId = session.id, chatRepository = app.chatRepository,
                providerRepository = app.providerRepository, appContext = app,
                memoryRepository = null, skillRepository = null, mcpRepository = null,
            ))[ChatViewModel::class.java].also {
                withTimeout(15_000) { it.nmAwaitSessionReady(); it.activeEntryId.first { id -> id == entry.id } }
            }
        }
        seedFocus()
    }

    /** 即使中途断言失败也只删除自己的ID，恢复默认指针、空组和首日派发标记。 */
    @After fun cleanup() = runBlocking {
        withContext(NonCancellable) {
            try { cleanupSession() }
            finally {
                try { cleanupFocus() }
                finally {
                    try { if (::scenario.isInitialized) scenario.close() }
                    finally {
                        try { restoreConfiguration() }
                        finally { if (::server.isInitialized) server.close() }
                    }
                }
            }
        }
    }

    /** 从正常发送到模型工具调用，再到真实FocusStore结果的完整普通聊天链路。 */
    @Test fun should_readPersistedFocus_andExposeOnlyReadTools_when_foregroundUserSends() = runBlocking {
        server.enqueueFocusQuery(focus.id, CALL_ID)
        server.enqueueText()
        sendFromActivity("查询这条专注记录：${focus.id}")
        assertReadSchema(server.take())
        assertFocusResult(server.take())
        awaitIdle()
        assertUserRowsPersisted(expectedCount = 1)
        assertEquals(focus, store.sessions().single { it.id == focus.id })
    }

    /** 真正点击新建聊天后，首次发送将草稿转为普通会话并保留这一条用户的读取授权。 */
    @Test fun should_readFocusAfterDraftPromotion_when_userClicksNewChatAndSendsFirstMessage() = runBlocking {
        val draftId = openNewDraftFromUi()
        assertNull("点击新建聊天不应预先创建Room会话", app.chatRepository.getSession(draftId))
        withContext(Dispatchers.Main) {
            assertEquals("", vm.realSessionId)
            assertTrue(vm.messages.value.none { it.role == "user" })
            vm.selectEntry(entry.id)
            assertEquals(entry.id, vm.activeEntryId.value)
        }
        assertNull("选择模型仍应保留未落盘草稿", app.chatRepository.getSession(draftId))
        val firstResponse = server.enqueueFocusQuery(focus.id, CALL_ID, hold = true)
        server.enqueueText()
        try {
            sendFromActivity("新聊天第一次发送：查询专注记录${focus.id}")
            assertReadSchema(server.take())
            val promotedId = withContext(Dispatchers.Main) { vm.realSessionId }
            assertTrue(promotedId.isNotBlank())
            assertFalse(promotedId.startsWith("__new__"))
            assertEquals(promotedId, ChatViewModelStore.resolvePersistedId(draftId))
            assertFalse("普通新聊天不能晋升为主要聊天", MainChat.isMain(app, promotedId))
            chatId = promotedId
            assertNotNull(app.chatRepository.getSession(promotedId))
            assertNull(app.chatRepository.getSession(draftId))
            val binding = JSONObject(requireNotNull(app.chatRepository.getSession(promotedId)?.modelBinding))
            assertEquals(entry.id, binding.getString("entryId"))
            assertUserRowsPersisted(expectedCount = 1)
            withContext(Dispatchers.Main) {
                assertSame(vm, ChatViewModelStore.existingViewModel(draftId))
                assertSame(vm, ChatViewModelStore.existingViewModel(promotedId))
                // 首次发送后通过正常改名入口固定标题，避免无关标题生成选择其他模型。
                vm.updateTitleAndCategory("新建草稿首次读取验收", null)
                withTimeout(10_000) { vm.sessionTitle.first { it == "新建草稿首次读取验收" } }
            }
            firstResponse.countDown()
            assertFocusResult(server.take())
            awaitIdle()
            assertUserRowsPersisted(expectedCount = 1)
            assertEquals(focus, store.sessions().single { it.id == focus.id })
        } finally { firstResponse.countDown() }
    }

    /** 应用同时在前台也不能给RPC来源签发个人记录权限。 */
    @Test fun should_hidePersonalRecordsTools_when_headlessPromptRunsWhileActivityIsForeground() = runBlocking {
        server.enqueueText("headless-fixture-complete")
        scenario.onActivity { assertTrue(app.isAppForeground()) }
        val result = HeadlessChatRunner.prompt(app, requireNotNull(chatId),
            "查询专注、待办和日记", wait = false, timeoutMs = 30_000)
        assertEquals("Running", result.status)
        val request = server.take()
        assertEquals(entry.model.id, request.body.getString("model"))
        assertTrue("后台来源暴露了个人查询：${request.toolNames()}",
            READ_TOOLS.intersect(request.toolNames()).isEmpty())
        assertNoCommands(request)
        awaitIdle()
        assertUserRowsPersisted(expectedCount = 1)
        assertEquals(focus, store.sessions().single { it.id == focus.id })
    }

    /** 入队时来自前台的人，消费时退后台仍保留来源，落盘ID必须替换所有占位ID。 */
    @Test fun should_keepReadAuthorization_andPromoteQueuedRow_when_userQueuesThenBackgrounds() = runBlocking {
        val firstResponse = server.enqueueText("first-fixture-complete", hold = true)
        server.enqueueFocusQuery(focus.id, CALL_ID)
        server.enqueueText()
        try {
            sendFromActivity("先回复一条简短消息")
            assertReadSchema(server.take())
            sendFromActivity("随后查询这条专注记录：${focus.id}")
            withContext(Dispatchers.Main) {
                assertEquals(1, vm.promptQueue.value.size)
                assertTrue(vm.messages.value.any { it.isQueued && it.id.startsWith("queued_msg_") })
            }
            scenario.moveToState(Lifecycle.State.CREATED)
            assertFalse("回归场景必须在消费队列前进入后台", app.isAppForeground())
            firstResponse.countDown()
            assertReadSchema(server.take())
            assertFocusResult(server.take())
            awaitIdle()
            assertUserRowsPersisted(expectedCount = 2)
            assertEquals(focus, store.sessions().single { it.id == focus.id })
        } finally { firstResponse.countDown() }
    }

    /** 旧重试的取消收尾延迟到新请求启动后，也不能清除新请求的Stop按钮与Job句柄。 */
    @Test fun should_keepReplacementStreaming_when_stoppedRetryFinishesPreparationLate() = runBlocking {
        server.enqueueText("retry-seed-complete")
        sendFromActivity("先建立可重试的普通回复")
        assertReadSchema(server.take())
        awaitIdle()
        val id = requireNotNull(chatId)
        val delayed = DelayedChatReads(app.chatRepository.dao, id)
        withContext(Dispatchers.Main) {
            ChatViewModelStore.release(id)
            vm = ViewModelProvider(ChatViewModelStore.ownerFor(id), ChatViewModel.factory(
                sessionId = id, chatRepository = ChatRepository(delayed.dao, app),
                providerRepository = app.providerRepository, appContext = app,
                memoryRepository = null, skillRepository = null, mcpRepository = null,
            ))[ChatViewModel::class.java]
            withTimeout(15_000) { vm.nmAwaitSessionReady(); vm.activeEntryId.first { it == entry.id } }
        }
        val response = server.enqueueText("replacement-complete", hold = true)
        try {
            delayed.arm()
            scenario.onActivity { vm.retryLast() }
            withTimeout(10_000) { delayed.entered.await() }
            val retryJob = withContext(Dispatchers.Main) { requireNotNull(vm.nmCurrentStreamJob()) }
            scenario.onActivity {
                assertTrue(vm.isStreaming.value)
                vm.cancelStream()
                assertFalse(vm.isStreaming.value)
                vm.sendMessage("停止重试后发送新的请求")
                assertTrue(vm.isStreaming.value)
            }
            assertReadSchema(server.take())
            val replacementJob = withContext(Dispatchers.Main) { requireNotNull(vm.nmCurrentStreamJob()) }
            assertNotSame(retryJob, replacementJob)
            delayed.release()
            withTimeout(10_000) { retryJob.join() }
            withContext(Dispatchers.Main) {
                assertTrue("旧准备任务收尾错误清掉新请求的忙碌状态", vm.isStreaming.value)
                assertSame("旧准备任务覆盖了新请求的取消句柄", replacementJob, vm.nmCurrentStreamJob())
                assertTrue(replacementJob.isActive)
            }
            response.countDown()
            awaitIdle()
            assertUserRowsPersisted(expectedCount = 2)
        } finally {
            delayed.release()
            response.countDown()
        }
    }

    private fun captureConfiguration() {
        val repository = app.providerRepository
        originalDefault = repository.defaultPrimaryGroupId
        originalSubDefault = repository.defaultSubGroupId
        originalLastUsed = repository.lastUsedEntryId
        originalEmptyGroups = repository.config.value.modelGroups
            .filter { it.memberEntryIds.isEmpty() }.map { it.copy(memberEntryIds = mutableListOf()) }
        hasCapturedDefaults = true
        val prefs = app.getSharedPreferences("nanomuse", Context.MODE_PRIVATE)
        hadFirstDay = prefs.contains("feed.first_day")
        originalFirstDay = prefs.getBoolean("feed.first_day", false)
        hadSetup = prefs.contains("setup.done")
        originalSetup = prefs.getBoolean("setup.done", false)
        hasCapturedFeed = true
        // 正常回合收尾会触发首日生成；测试暂时禁用派发并在清理时精确恢复。
        check(prefs.edit().putBoolean("feed.first_day", true).putBoolean("setup.done", true).commit())
    }

    private fun addProvider() {
        val id = "records-loopback-${UUID.randomUUID()}"
        instanceId = id
        app.providerRepository.addInstance(ProviderInstance(id, "个人记录本地测试", ProviderType.openAI,
            ProviderCredential.apiKey, customBaseURL = server.baseUrl, appendV1Suffix = false))
        // 自定义回环提供商支持空密钥，无需创建或读取任何真实凭据。
        app.providerRepository.addEntry(ModelEntry(id, LLMModel("fixture-personal-records",
            "记录工具测试模型", "本地夹具", contextWindow = 131_072, maxOutputTokens = 256)))
        entry = app.providerRepository.config.value.modelEntries.single { it.providerInstanceId == id }
    }

    private suspend fun seedFocus() {
        store = FocusStore.get(app)
        check(store.dao.active(store.ownerKey) == null) { "测试包已有活动专注，请先结束该计时" }
        val now = System.currentTimeMillis()
        focus = FocusSession(ownerKey = store.ownerKey, id = "records-focus-${UUID.randomUUID()}",
            title = "普通聊天读取的独立专注夹具", taskId = null, groupName = "集成验收",
            tagsJson = "[\"fixture\"]", mode = "stopwatch", targetMs = 60_000,
            status = "finished", elapsedMs = 38_072, startedAt = now - 38_072,
            endedAt = now, updatedAt = now, runningWall = now, runningElapsed = 0,
            bootCount = FocusStore.boot(app))
        // 固定完成记录只用于验证读取；通过真实共享Room写入，不注入工具返回值。
        store.transaction { store.dao.putSession(focus) }
        assertEquals(focus, store.sessions().single { it.id == focus.id })
    }

    private fun sendFromActivity(text: String) {
        scenario.onActivity {
            assertTrue(app.isAppForeground())
            assertEquals(Lifecycle.State.RESUMED, it.lifecycle.currentState)
            vm.sendMessage(text)
            assertTrue("正常发送入口未启动：${vm.error.value}", vm.isStreaming.value)
        }
    }

    private suspend fun openNewDraftFromUi(): String {
        // 其余用例的空会话不参与本例，草稿和VM必须由真实菜单回调建立。
        cleanupSession()
        val previous = withTimeout(15_000) {
            while (ChatViewModelStore.activeSessionId == null) delay(50)
            requireNotNull(ChatViewModelStore.activeSessionId)
        }
        clickControl(app.getString(R.string.nm_more), "More")
        clickControl(app.getString(R.string.chat_menu_new_chat))
        var selectedDraft: String? = null
        withTimeout(15_000) {
            while (selectedDraft == null) {
                val current = ChatViewModelStore.activeSessionId
                if (current != null && current != previous && current.startsWith("__new__")) {
                    selectedDraft = current
                } else {
                    delay(50)
                }
            }
        }
        val draftId = requireNotNull(selectedDraft)
        chatId = draftId
        withContext(Dispatchers.Main) {
            vm = requireNotNull(ChatViewModelStore.existingViewModel(draftId))
            withTimeout(15_000) { vm.nmAwaitSessionReady() }
        }
        assertFalse(MainChat.isMain(app, draftId))
        return draftId
    }

    private suspend fun clickControl(vararg labels: String) {
        withTimeout(15_000) {
            while (true) {
                val control = findControl(labels.toSet())
                if (control != null) {
                    assertTrue("点击失败：${labels.toList()}",
                        control.performAction(AccessibilityNodeInfo.ACTION_CLICK))
                    return@withTimeout
                }
                delay(50)
            }
        }
    }

    private fun findControl(labels: Set<String>): AccessibilityNodeInfo? {
        val pending = java.util.ArrayDeque<AccessibilityNodeInfo>()
        InstrumentationRegistry.getInstrumentation().uiAutomation.rootInActiveWindow?.let(pending::add)
        while (pending.isNotEmpty()) {
            val node = pending.removeFirst()
            if (node.isVisibleToUser && (node.text?.toString() in labels ||
                    node.contentDescription?.toString() in labels)) {
                clickableParent(node)?.takeIf { it.isEnabled }?.let { return it }
            }
            for (index in 0 until node.childCount) node.getChild(index)?.let(pending::add)
        }
        return null
    }

    private fun clickableParent(node: AccessibilityNodeInfo): AccessibilityNodeInfo? {
        var current: AccessibilityNodeInfo? = node
        while (current != null && !current.isClickable) current = current.parent
        return current
    }

    private fun assertReadSchema(request: PersonalRecordsLoopbackProvider.Request) {
        assertEquals("/v1/chat/completions", request.path)
        assertEquals(entry.model.id, request.body.getString("model"))
        assertTrue("缺少普通聊天查询schema：${request.toolNames()}", request.toolNames().containsAll(READ_TOOLS))
        assertNoCommands(request)
    }

    private fun assertNoCommands(request: PersonalRecordsLoopbackProvider.Request) {
        assertTrue("普通聊天不能声明个人记录写命令：${request.toolNames()}",
            COMMAND_TOOLS.intersect(request.toolNames()).isEmpty())
    }

    private fun assertFocusResult(request: PersonalRecordsLoopbackProvider.Request) {
        assertReadSchema(request)
        val result = request.toolResult(CALL_ID)
        assertTrue("真实工具执行失败：$result", result.getBoolean("success"))
        val record = result.getJSONObject("data")
        assertEquals(focus.id, record.getString("id"))
        assertEquals(focus.title, record.getString("title"))
        assertEquals(focus.elapsedMs, record.getLong("elapsedMs"))
        assertEquals(focus.status, record.getString("status"))
        assertEquals("minis://views/focus", result.getString("view_url"))
    }

    private suspend fun awaitIdle() = withContext(Dispatchers.Main) {
        withTimeout(30_000) { vm.isStreaming.first { !it } }
        assertNull("正常聊天结束后不应存在错误", vm.error.value)
        assertTrue(vm.promptQueue.value.isEmpty())
    }

    private suspend fun assertUserRowsPersisted(expectedCount: Int) {
        val storedRows = app.chatRepository.loadMessages(requireNotNull(chatId))
        val rows = storedRows.filter { row -> row.role == "user" && !isToolResultOnly(row) }
        withContext(Dispatchers.Main) {
            val users = vm.messages.value.filter { it.role == "user" }
            // 断言前保存原始行类型与UI身份，失败时仍可核对工具结果是否被误算。
            evidenceFile.appendText(JSONObject().put("kind", "user_row_assertion")
                .put("expectedCount", expectedCount)
                .put("storedRows", JSONArray(storedRows.map { row ->
                    JSONObject().put("id", row.id).put("role", row.role)
                        .put("partTypes", JSONArray(partTypes(row)))
                })).put("visibleUserIds", JSONArray(users.map { it.id }))
                .put("isStreaming", vm.isStreaming.value).toString() + "\n")
            assertEquals(expectedCount, rows.size)
            assertEquals(expectedCount, users.size)
            assertEquals(rows.map { it.id }, users.map { it.id })
            assertFalse(users.any { it.isQueued || it.id.startsWith("queued_msg_") })
        }
    }

    private fun isToolResultOnly(row: MessageEntity): Boolean {
        val types = partTypes(row)
        return types.isNotEmpty() && types.all { it == "toolResult" }
    }

    private fun partTypes(row: MessageEntity): List<String> {
        val parts = JSONArray(row.partsJson)
        return (0 until parts.length()).map { parts.getJSONObject(it).getString("type") }
    }

    private suspend fun cleanupSession() {
        val hostId = chatId ?: return
        var persistedId = ChatViewModelStore.resolvePersistedId(hostId)
        try {
            val scopeJob = withContext(Dispatchers.Main) {
                val job = if (::vm.isInitialized) vm.viewModelScope.coroutineContext[Job] else null
                if (::vm.isInitialized) {
                    vm.promptQueue.value.toList().forEach { vm.removeQueuedPrompt(it.id) }
                    vm.cancelStream()
                    persistedId = vm.realSessionId.ifEmpty { persistedId }
                }
                ChatViewModelStore.release(hostId)
                // Headless包装器也缓存Provider；只移除本测试ID，避免保留已释放VM引用。
                val cache = HeadlessChatRunner::class.java.getDeclaredField("providers")
                    .apply { isAccessible = true }.get(HeadlessChatRunner) as MutableMap<*, *>
                cache.remove(hostId)
                cache.remove(persistedId)
                job
            }
            // 等待取消收尾的不可取消Room提交完成，再删除测试会话，避免迟到记录重现。
            withTimeout(15_000) { scopeJob?.join() }
        } finally {
            try { app.chatRepository.dao.deleteConversation(persistedId) }
            finally { SyncDatabase.get(app).dao().removeOwners(listOf(persistedId, hostId).distinct()) }
        }
    }

    private suspend fun cleanupFocus() {
        if (!::focus.isInitialized) return
        store.database.withTransaction {
            store.database.openHelper.writableDatabase.execSQL(
                "DELETE FROM focus_sessions WHERE ownerKey=? AND id=?", arrayOf(focus.ownerKey, focus.id))
        }
        assertNull(store.dao.session(focus.ownerKey, focus.id))
    }

    private fun restoreConfiguration() {
        if (!::app.isInitialized) return
        try {
            instanceId?.let(app.providerRepository::removeInstance)
        } finally {
            if (hasCapturedDefaults) {
                originalEmptyGroups.filter { app.providerRepository.group(it.id) == null }
                    .forEach(app.providerRepository::addGroup)
                app.providerRepository.defaultPrimaryGroupId = originalDefault
                app.providerRepository.defaultSubGroupId = originalSubDefault
                app.providerRepository.lastUsedEntryId = originalLastUsed
            }
            if (hasCapturedFeed) {
                val editor = app.getSharedPreferences("nanomuse", Context.MODE_PRIVATE).edit()
                if (hadFirstDay) editor.putBoolean("feed.first_day", originalFirstDay)
                else editor.remove("feed.first_day")
                if (hadSetup) editor.putBoolean("setup.done", originalSetup)
                else editor.remove("setup.done")
                check(editor.commit())
            }
        }
        assertFalse(app.providerRepository.config.value.instances.any { it.id == instanceId })
        assertFalse(app.providerRepository.config.value.modelEntries.any { it.providerInstanceId == instanceId })
    }

    /** 只延迟一次真实DAO查询边界，不伪造VM、授权或状态逻辑；模拟迟到的数据库准备收尾。 */
    private class DelayedChatReads(private val delegate: ChatDao, private val sessionId: String) {
        private val isArmed = AtomicBoolean(false)
        private val released = CompletableDeferred<Unit>()
        val entered = CompletableDeferred<Unit>()
        val dao: ChatDao = Proxy.newProxyInstance(ChatDao::class.java.classLoader,
            arrayOf(ChatDao::class.java)) { _, method, arguments ->
            val args = arguments.orEmpty()
            if (method.name == "loadMessagesPage" && args.firstOrNull() == sessionId &&
                isArmed.compareAndSet(true, false)) {
                @Suppress("UNCHECKED_CAST")
                val continuation = args.last() as Continuation<List<MessageEntity>>
                val operation: suspend () -> List<MessageEntity> = {
                    withContext(NonCancellable) { entered.complete(Unit); released.await() }
                    currentCoroutineContext().ensureActive()
                    delegate.loadMessagesPage(sessionId, args[1] as Int, args[2] as Int)
                }
                operation.startCoroutine(continuation)
                COROUTINE_SUSPENDED
            } else {
                try { method.invoke(delegate, *args) }
                catch (error: InvocationTargetException) { throw error.targetException }
            }
        } as ChatDao

        /** VM加载结束后才开启延迟，确保拦住重试准备而非初始化。 */
        fun arm() { check(isArmed.compareAndSet(false, true)) }

        /** 测试失败也能释放不可取消的边界等待。 */
        fun release() { released.complete(Unit) }
    }

    private companion object {
        const val CALL_ID = "call_focus_records_fixture"
        val READ_TOOLS = setOf("focus_query", "todo_query", "personal_records_query")
        val COMMAND_TOOLS = setOf("focus_command", "todo_command", "personal_records_command")
    }
}
