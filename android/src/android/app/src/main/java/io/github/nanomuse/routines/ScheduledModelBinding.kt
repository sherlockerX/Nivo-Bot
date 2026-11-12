package io.github.nanomuse.routines

import androidx.lifecycle.ViewModelProvider
import com.openminis.app.MinisApp
import com.openminis.app.scheduled.ScheduledTask
import com.openminis.app.ui.chat.ChatViewModel
import com.openminis.app.ui.chat.ChatViewModelStore
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull

/** 专属任务会话每次同步真实VM与存储模型，不经过会改变全局默认的模型选择UI。 */
object ScheduledModelBinding {
    /** 会话运行身份已经由调度器占用，冷VM和热VM都应用同一绑定。 */
    suspend fun apply(app: MinisApp, sessionId: String, task: ScheduledTask, runId: String,
        account: ScheduledAccountAccess): Boolean = withContext(Dispatchers.Main) {
        account.requireCurrent(app)
        val vm = ViewModelProvider(ChatViewModelStore.ownerFor(sessionId), ChatViewModel.factory(
            sessionId = sessionId, chatRepository = app.chatRepository,
            providerRepository = app.providerRepository, appContext = app,
            memoryRepository = app.memoryRepository, skillRepository = app.skillRepository,
            mcpRepository = app.mcpRepository))[ChatViewModel::class.java]
        val ready = withTimeoutOrNull(5_000) { vm.nmAwaitSessionReady(); true } == true
        if (!ready) return@withContext false
        account.requireCurrent(app)
        account.locked(app) { vm.nmApplyScheduledModel(task.modelBinding, task.modelId, runId) }
    }
}
