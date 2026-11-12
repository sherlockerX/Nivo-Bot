package io.github.nanomuse.account

import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.openminis.app.MinisApp
import com.openminis.app.data.repository.MemoryRepository
import com.openminis.app.ui.chat.ChatViewModel
import com.openminis.app.ui.chat.ChatViewModelStore
import io.github.nanomuse.sync.ConversationSync
import io.github.nanomuse.sync.SyncDatabase
import java.nio.file.Files
import java.util.UUID
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

/** 真实VM与Room的账号代次回归，只使用隔离包和专属临时记忆目录。 */
@RunWith(AndroidJUnit4::class)
class AccountChatOperationInstrumentedTest {
    @Test fun should_cancelVmAndRejectMemoryAndRoom_when_accountTransitionStarts() = runBlocking {
        val app = ApplicationProvider.getApplicationContext<MinisApp>()
        check(app.packageName.endsWith(".uitest")) { "只允许隔离测试包" }
        val directory = Files.createTempDirectory(app.cacheDir.toPath(), "account-chat-").toFile()
        val memory = MemoryRepository(directory)
        val session = app.chatRepository.createSession("fixture-${UUID.randomUUID()}", memoryEnabled = true)
        val operation = AccountData.captureOperation()
        try {
            val vm = withContext(Dispatchers.Main) {
                ViewModelProvider(ChatViewModelStore.ownerFor(session.id), ChatViewModel.factory(
                    sessionId = session.id, chatRepository = app.chatRepository,
                    providerRepository = app.providerRepository, appContext = app,
                    memoryRepository = memory, skillRepository = null, mcpRepository = null,
                ))[ChatViewModel::class.java].also { withTimeout(10_000) { it.nmAwaitSessionReady() } }
            }
            withContext(Dispatchers.Main) {
                assertTrue(vm.executeMemoryWrite(JSONObject().put("content", "fixture-a").toString()).success)
            }
            val before = directory.listFiles().orEmpty().associate { it.name to it.readText() }
            ConversationSync.exclusive { AccountData.withTransition { } }
            withContext(Dispatchers.Main) {
                assertTrue(vm.viewModelScope.coroutineContext[Job]!!.isCancelled)
                assertTrue(runCatching { vm.executeMemoryGet("{}") }.isFailure)
                assertTrue(runCatching {
                    vm.executeMemoryWrite(JSONObject().put("content", "stale").toString())
                }.isFailure)
            }
            val lateWrite = runCatching {
                withContext(operation) { app.chatRepository.appendMessage(session.id, "assistant", "[]") }
            }
            assertTrue(lateWrite.isFailure)
            assertEquals(0, app.chatRepository.messageCount(session.id))
            assertEquals(before, directory.listFiles().orEmpty().associate { it.name to it.readText() })
        } finally {
            withContext(Dispatchers.Main) { ChatViewModelStore.release(session.id) }
            app.chatRepository.dao.deleteConversation(session.id)
            SyncDatabase.get(app).dao().removeOwners(listOf(session.id))
            directory.listFiles().orEmpty().forEach { it.delete() }
            directory.delete()
        }
    }
}
