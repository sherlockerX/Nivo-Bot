package io.github.nanomuse.routines

import androidx.lifecycle.ViewModelProvider
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.openminis.app.MinisApp
import com.openminis.app.crash.CrashFrequencyDetector
import com.openminis.app.data.model.LLMMessage
import com.openminis.app.data.model.LLMModel
import com.openminis.app.data.model.ModelEntry
import com.openminis.app.data.model.ModelGroup
import com.openminis.app.data.model.ProviderCredential
import com.openminis.app.data.model.ProviderInstance
import com.openminis.app.data.model.ProviderType
import com.openminis.app.provider.LLMProvider
import com.openminis.app.scheduled.ScheduledRepeatMode
import com.openminis.app.scheduled.ScheduledTask
import com.openminis.app.ui.chat.ChatViewModel
import com.openminis.app.ui.chat.ChatViewModelStore
import io.github.nanomuse.account.AccountData
import io.github.nanomuse.coach.CoachRuntime
import io.github.nanomuse.models.ModelSlots
import io.github.nanomuse.sync.SyncDatabase
import java.util.UUID
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/** 仅隔离测试包可运行；唯一夹具使用回环SSE服务，无真实凭据或外部模型请求。 */
@RunWith(AndroidJUnit4::class)
class ScheduledModelBindingInstrumentedTest {
    private lateinit var app: MinisApp
    private lateinit var server: ScheduledLoopbackProvider
    private lateinit var entryA: ModelEntry
    private lateinit var entryB: ModelEntry
    private lateinit var targetGroup: ModelGroup
    private lateinit var defaultGroup: ModelGroup
    private lateinit var chatId: String
    private lateinit var scheduledRun: ScheduledRunScope
    private var originalDefault: String? = null
    private var originalSubDefault: String? = null
    private var originalLastUsed: String? = null
    private var originalEmptyGroups: List<ModelGroup> = emptyList()
    private var hasCapturedDefaults = false
    private val instanceIds = mutableListOf<String>()
    private val groupIds = mutableListOf<String>()
    private val taskId = "model-test-${UUID.randomUUID()}"

    /** ProviderDatabase为进程单例，因此仅追加唯一夹具，并保存需要恢复的默认指针。 */
    @Before fun prepare() = runBlocking {
        app = ApplicationProvider.getApplicationContext()
        check(app.packageName.endsWith(".uitest")) { "测试只能运行于隔离.uitest应用" }
        check(app.subsystemsReady())
        withTimeout(10_000) { app.providerRepository.awaitConfigLoaded() }
        originalDefault = app.providerRepository.defaultPrimaryGroupId
        originalSubDefault = app.providerRepository.defaultSubGroupId
        originalLastUsed = app.providerRepository.lastUsedEntryId
        originalEmptyGroups = app.providerRepository.config.value.modelGroups.filter { it.memberEntryIds.isEmpty() }
            .map { it.copy(memberEntryIds = mutableListOf()) }
        hasCapturedDefaults = true
        server = ScheduledLoopbackProvider()
        entryA = addProvider("a")
        entryB = addProvider("b")
        targetGroup = addGroup("目标组", entryB)
        defaultGroup = addGroup("默认组", entryA)
        app.providerRepository.defaultPrimaryGroupId = defaultGroup.id
        app.providerRepository.lastUsedEntryId = entryB.id
        chatId = app.chatRepository.createSession(entryA.model.id, "调度隔离夹具", memoryEnabled = false,
            source = "scheduled", taskId = taskId).id
        scheduledRun = ScheduledRunScope(taskId)
        assertTrue(ScheduledRunScopes.enter(chatId, scheduledRun))
    }

    /** 只清理自己创建的ID，恢复全局指针；不清空其他提供商、聊天或凭据。 */
    @After fun cleanup() = runBlocking {
        if (::chatId.isInitialized) {
            if (::scheduledRun.isInitialized) ScheduledRunScopes.leave(chatId, scheduledRun)
            withContext(Dispatchers.Main) { ChatViewModelStore.release(chatId) }
            app.chatRepository.dao.deleteConversation(chatId)
            SyncDatabase.get(app).dao().removeOwners(listOf(chatId))
        }
        groupIds.forEach { app.providerRepository.removeGroup(it) }
        instanceIds.forEach { app.providerRepository.removeInstance(it) }
        // 现有removeInstance会顺便清理所有空组，恢复原有空组避免夹具清理改变其他配置。
        originalEmptyGroups.filter { app.providerRepository.group(it.id) == null }
            .forEach { app.providerRepository.addGroup(it) }
        if (hasCapturedDefaults) {
            app.providerRepository.defaultPrimaryGroupId = originalDefault
            app.providerRepository.defaultSubGroupId = originalSubDefault
            app.providerRepository.lastUsedEntryId = originalLastUsed
        }
        if (::server.isInitialized) server.close()
    }

    @Test fun should_routeThroughCurrentProvider_andPersistBinding_withoutChangingGlobalDefaults() = runBlocking {
        val originalSlot = ModelSlots.lastChanged.value
        val originalRevision = app.providerRepository.config.value.revision
        applyAndVerify(entryBinding(entryA), null, entryA, null, "a")
        applyAndVerify(entryBinding(entryB), null, entryB, null, "b")
        applyAndVerify(groupBinding(targetGroup), null, entryB, targetGroup.id, "b")
        applyAndVerify(null, null, entryA, defaultGroup.id, "a")
        assertEquals(defaultGroup.id, app.providerRepository.defaultPrimaryGroupId)
        assertEquals(entryB.id, app.providerRepository.lastUsedEntryId)
        assertEquals(originalRevision, app.providerRepository.config.value.revision)
        assertEquals(originalSlot, ModelSlots.lastChanged.value)
        assertEquals(listOf(entryA.id), app.providerRepository.group(defaultGroup.id)!!.memberEntryIds)
        assertEquals(listOf(entryB.id), app.providerRepository.group(targetGroup.id)!!.memberEntryIds)
    }

    @Test fun should_applyLegacyModelId_andPreserveVmAndRoom_when_newBindingIsInvalid() = runBlocking {
        applyAndVerify(null, entryB.model.id, entryB, null, "b")
        assertInvalidBindingPreserves(entryB, null)
        applyAndVerify(groupBinding(targetGroup), null, entryB, targetGroup.id, "b")
        assertInvalidBindingPreserves(entryB, targetGroup.id)
        assertEquals(defaultGroup.id, app.providerRepository.defaultPrimaryGroupId)
        applyAndVerify(null, null, entryA, defaultGroup.id, "a")
    }

    @Test fun should_refuseWrongRunWithoutChangingProvider_when_anotherRunOwnsConversation() = runBlocking {
        applyAndVerify(entryBinding(entryA), null, entryA, null, "a")
        val vm = existingVm()
        val rowBefore = requireNotNull(app.chatRepository.getSession(chatId))
        withContext(Dispatchers.Main) {
            val before = provider(vm)
            assertFalse(vm.nmApplyScheduledModel(entryBinding(entryB), null, UUID.randomUUID().toString()))
            assertSame(before, provider(vm))
        }
        assertEquals(rowBefore.modelBinding, app.chatRepository.getSession(chatId)!!.modelBinding)
    }

    @Test fun should_unregisterSafeModeListener_when_realViewModelStoreClears() = runBlocking {
        withContext(Dispatchers.Main) {
            val before = listenerCount()
            val store = ChatViewModelStore.ownerFor(chatId).viewModelStore
            val vm = existingVm()
            withTimeout(10_000) { vm.nmAwaitSessionReady() }
            assertEquals(before + 1, listenerCount())
            store.clear()
            assertEquals(before, listenerCount())
            store.clear()
            assertEquals(before, listenerCount())
        }
    }

    @Test fun should_keepScheduledAuthorization_when_coachRefreshesWithinSameAccount() = runBlocking {
        val account = ScheduledAccountAccess.capture(app)
        val started = CompletableDeferred<Unit>()
        val finish = CompletableDeferred<Unit>()
        val work = async { account.running(app) { started.complete(Unit); finish.await(); "completed" } }
        started.await()
        val accountEpoch = AccountData.epoch.value
        CoachRuntime.reset()
        assertEquals(accountEpoch, AccountData.epoch.value)
        assertTrue(account.isCurrent(app))
        assertTrue(work.isActive)
        finish.complete(Unit)
        assertEquals("completed", withTimeout(5_000) { work.await() })
    }

    @Test fun should_reloadLastUsedDefault_when_noDefaultGroupIsConfigured() = runBlocking {
        app.providerRepository.defaultPrimaryGroupId = null
        val beforeLastUsed = app.providerRepository.lastUsedEntryId
        assertTrue(ScheduledModelBinding.apply(app, chatId, task(null, null), scheduledRun.runId,
            ScheduledAccountAccess.capture(app)))
        withContext(Dispatchers.Main) {
            val vm = existingVm()
            assertEquals(entryB.id, vm.activeEntryId.value)
            assertNull(vm.selectedGroupId.value)
            assertEquals(entryB.model.id, requireNotNull(provider(vm)).model.id)
        }
        val saved = JSONObject(requireNotNull(app.chatRepository.getSession(chatId)!!.modelBinding))
        assertEquals("entry", saved.getString("type"))
        assertEquals(entryB.id, saved.getString("entryId"))
        assertNull(app.providerRepository.defaultPrimaryGroupId)
        assertEquals(beforeLastUsed, app.providerRepository.lastUsedEntryId)
    }

    private suspend fun applyAndVerify(binding: String?, modelId: String?, expected: ModelEntry,
        groupId: String?, route: String) {
        assertTrue(withTimeout(10_000) { ScheduledModelBinding.apply(app, chatId, task(binding, modelId),
            scheduledRun.runId, ScheduledAccountAccess.capture(app)) })
        val current = withContext(Dispatchers.Main) {
            val vm = existingVm()
            assertEquals(expected.id, vm.activeEntryId.value)
            assertEquals(groupId, vm.selectedGroupId.value)
            assertEquals(expected.model.displayName, vm.modelName.value)
            requireNotNull(provider(vm)).also { assertEquals(expected.model.id, it.model.id) }
        }
        val row = requireNotNull(app.chatRepository.getSession(chatId))
        assertEquals(expected.model.id, row.modelId)
        val saved = JSONObject(requireNotNull(row.modelBinding))
        assertEquals(if (groupId == null) "entry" else "group", saved.getString("type"))
        assertEquals(groupId ?: expected.id, saved.getString(if (groupId == null) "entryId" else "groupId"))
        if (groupId != null) assertEquals(expected.id, saved.getString("lastEntryId"))
        // 读取当前真实Provider后检查回环地址，再向它发送唯一合成消息，验证实际线路与model字段。
        val basePath = current.javaClass.getDeclaredField("basePath").apply { isAccessible = true }.get(current)
        assertEquals(server.baseUrl(route), basePath)
        val response = withTimeout(10_000) {
            current.sendMessage(listOf(LLMMessage(LLMMessage.Role.USER, "synthetic-model-selection-check")),
                systemPrompt = null, maxTokens = 32)
        }
        assertEquals("fixture-ok", response.text)
        val request = server.take()
        assertEquals("/$route/v1/chat/completions", request.path)
        assertEquals(expected.model.id, request.model)
        assertEquals(defaultGroup.id, app.providerRepository.defaultPrimaryGroupId)
        assertEquals(entryB.id, app.providerRepository.lastUsedEntryId)
    }

    private suspend fun assertInvalidBindingPreserves(expected: ModelEntry, groupId: String?) {
        val rowBefore = requireNotNull(app.chatRepository.getSession(chatId))
        val vm = existingVm()
        val providerBefore = withContext(Dispatchers.Main) { provider(vm) }
        assertFalse(ScheduledModelBinding.apply(app, chatId,
            task("{\"type\":\"entry\",\"entryId\":\"missing-test-entry\"}", null), scheduledRun.runId,
            ScheduledAccountAccess.capture(app)))
        withContext(Dispatchers.Main) {
            assertSame(providerBefore, provider(vm))
            assertEquals(expected.id, vm.activeEntryId.value)
            assertEquals(expected.model.displayName, vm.modelName.value)
            assertEquals(groupId, vm.selectedGroupId.value)
        }
        assertEquals(rowBefore.modelBinding, app.chatRepository.getSession(chatId)!!.modelBinding)
        assertEquals(rowBefore.modelId, app.chatRepository.getSession(chatId)!!.modelId)
    }

    private fun existingVm(): ChatViewModel = ViewModelProvider(ChatViewModelStore.ownerFor(chatId),
        ChatViewModel.factory(chatId, app.chatRepository, app.providerRepository, app,
            app.memoryRepository, app.skillRepository, app.mcpRepository))[ChatViewModel::class.java]

    private fun provider(vm: ChatViewModel): LLMProvider? = ChatViewModel::class.java
        .getDeclaredField("currentProvider").apply { isAccessible = true }.get(vm) as? LLMProvider

    private fun listenerCount(): Int = (CrashFrequencyDetector::class.java.getDeclaredField("listeners")
        .apply { isAccessible = true }.get(CrashFrequencyDetector) as Collection<*>).size

    private fun addProvider(route: String): ModelEntry {
        val id = "sched-test-$route-${UUID.randomUUID()}"
        instanceIds.add(id)
        app.providerRepository.addInstance(ProviderInstance(id, "调度测试$route", ProviderType.openAI,
            ProviderCredential.apiKey, customBaseURL = server.baseUrl(route), appendV1Suffix = false))
        app.providerRepository.addEntry(ModelEntry(id, LLMModel("fixture-$route", "模型$route", "本地夹具",
            contextWindow = 8192, maxOutputTokens = 256)))
        return app.providerRepository.config.value.modelEntries.single { it.providerInstanceId == id }
    }

    private fun addGroup(label: String, entry: ModelEntry): ModelGroup {
        val group = ModelGroup(name = label, memberEntryIds = mutableListOf(entry.id))
        groupIds.add(group.id)
        app.providerRepository.addGroup(group)
        return group
    }

    private fun task(binding: String?, modelId: String?) = ScheduledTask(id = taskId, label = "调度隔离夹具",
        timeOfDayHour = 9, timeOfDayMinute = 0, repeatMode = ScheduledRepeatMode.DAILY,
        prompt = "synthetic", origin = "user_ui", modelBinding = binding, modelId = modelId)

    private fun entryBinding(entry: ModelEntry) = JSONObject().put("type", "entry").put("entryId", entry.id).toString()
    private fun groupBinding(group: ModelGroup) = JSONObject().put("type", "group").put("groupId", group.id).toString()
}
