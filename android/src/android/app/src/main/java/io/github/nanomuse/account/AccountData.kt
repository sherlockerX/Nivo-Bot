package io.github.nanomuse.account

import android.content.Context
import androidx.room.withTransaction
import com.openminis.app.MinisApp
import com.openminis.app.logging.AppLogger
import com.openminis.app.scheduled.ScheduledTask
import com.openminis.app.scheduled.ScheduledTaskManager
import io.github.nanomuse.cloud.NanoMuseCloud
import io.github.nanomuse.sync.SessionOwner
import io.github.nanomuse.sync.SyncDatabase
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/**
 * What of this phone belongs to the signed-in account, and what happens to it when the
 * account leaves (contract C12, 0.1.40; the table is in `docs/sync.md`).
 *
 * - **Chats** are rows in OpenMinis' database; each has an owner row in ours
 *   (`session_owners`), written the first time the session is seen ([reconcile], [claim]).
 *   The lists show the signed-in owner's; a sign-out without *Keep* deletes the account's
 *   rows, messages, attachments (hands traces included) and sync mappings.
 * - **Files** — the agent's memory of the person (`minis-global/memory`), the feed, the
 *   goals, the face, the shared workspace ([AccountScope.accountPaths]) — and the account's
 *   **preferences** ([AccountScope.accountPrefPrefixes]) and **routines** (the scheduled
 *   tasks) sit at their fixed paths while the account is signed in, so upstream reads them
 *   where it always did. When the account leaves they are put aside under
 *   `minis-global/nanomuse/accounts/<key>/` (*Keep*) or deleted, and the next account's
 *   come back from its own folder or start empty. Signed out, the phone's own set
 *   (`_local`) is in place.
 * - Settings (providers and keys, appearance, hands, the hub's device identity, grants) are
 *   the phone's and never move.
 */
object AccountData {
    private const val TAG = "AccountData"
    private const val PREFS = "nanomuse"
    private const val STASH = "minis-global/nanomuse/accounts"

    private val mutations = AccountMutationGate()
    /** 任务与页面使用真实账号迁移代次，普通教练reset不会触发账号变化。 */
    val epoch: kotlinx.coroutines.flow.StateFlow<Long> = mutations.epoch
    @Volatile private var app: Context? = null
    private var pendingMigration: PendingMigration? = null

    /** 进程内失败重试只继续原迁移，不能将已恢复的新空间再归档成旧账号。 */
    private data class PendingMigration(
        val root: String, val from: String, val to: String, val keep: Boolean,
        var hasLeft: Boolean = false,
        var hasSavedPreferences: Boolean = false,
        var hasSavedRoutines: Boolean = false,
        val departedPaths: MutableSet<String> = mutableSetOf(),
        val restoredPaths: MutableSet<String> = mutableSetOf(),
    )

    /** App start; the hooks in upstream code find the context here. */
    fun init(context: Context) {
        app = context.applicationContext
    }

    /** The key the signed-in account's data is filed under; [AccountScope.LOCAL] while signed out. */
    fun key(context: Context): String =
        AccountScope.key(NanoMuseCloud.account(context)?.accountId, NanoMuseCloud.apiKey(context))

    /** nanoMuse: 任务执行入口必须拒绝迁移中或迁移失败后尚未恢复的账号空间。 */
    fun requireAvailable() {
        mutations.requireAvailable()
    }

    /** nanoMuse: 聊天及异步文件任务固定发起代次，不能在账号切换后重新授权。 */
    fun captureOperation(): AccountOperation = mutations.operations.capture()

    /** 待办固定发起账号及代次，并与身份迁移共用互斥边界。 */
    suspend fun <T> withTodoOwnerMutation(
        expectedOwner: String,
        expectedEpoch: Long,
        block: suspend () -> T,
    ): T = mutations.exclusive {
        val context = checkNotNull(app) { "Account storage is not initialized" }
        if (epoch.value != expectedEpoch || key(context) != expectedOwner) {
            throw kotlinx.coroutines.CancellationException("The account changed; reopen the task page")
        }
        block()
    }

    private fun prefs(context: Context) = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    // -- whose chat is whose ------------------------------------------------------------------

    /**
     * Every session has an owner after this; returns the sessions the lists leave out for
     * [current] (the signed-in account's key, or the one given). Cheap: two small queries.
     */
    suspend fun reconcile(context: Context, current: String? = null): Set<String> = mutations.exclusive {
        reconcileLocked(context, current ?: key(context))
    }

    /** 已持迁移锁时直接使用，避免leave和enter重复获取同一个Mutex。 */
    private suspend fun reconcileLocked(context: Context, current: String): Set<String> {
        val ctx = context.applicationContext
        val repo = (ctx as? MinisApp)?.chatRepositoryOrNull ?: return emptySet()
        val dao = SyncDatabase.get(ctx).dao()
        val ids = repo.dao.listSessions().map { it.id }
        val owners = dao.owners().associate { it.sessionId to it.owner }
        val syncOwners = dao.conversations().associate { it.sessionId to it.owner }
        val r = AccountScope.reconcile(ids, owners, syncOwners, current)
        if (r.claimed.isNotEmpty()) dao.claimOwners(r.claimed.map { (id, owner) -> SessionOwner(id, owner) })
        // 先登记后插入的归属是恢复凭证，不能仅凭聊天行暂时不存在就删除。
        // 明确删除账号数据时由deleteChats移除；普通清理保留小型归属行。
        return dao.owners().filter { it.sessionId in ids && it.owner != current }.map { it.sessionId }.toSet()
    }

    /** 登记归属与会话插入共享迁移边界；无应用上下文的独立测试只操作自己的内存库。 */
    suspend fun <T> withSessionCreation(context: Context? = app, block: suspend (String?) -> T): T {
        val ctx = context?.applicationContext ?: return block(null)
        return mutations.create({ key(ctx) }) { owner -> block(owner) }
    }

    /** 身份切换前封闭教练服务，完整恢复文件后才发布新空间。 */
    suspend fun <T> withTransition(block: suspend () -> T): T = mutations.transition {
        io.github.nanomuse.coach.CoachRuntime.beginTransition()
        io.github.nanomuse.ui.focus.FocusUi.taskId.value = null
        io.github.nanomuse.ui.focus.FocusUi.exportRequested.value = false
        // 不在finally中恢复；迁移失败时保持关闭，避免暴露半迁移目录。
        val result = block()
        io.github.nanomuse.coach.CoachRuntime.finishTransition()
        result
    }

    /** 已持迁移锁时准备目标空间；同一进程内失败只允许重试同一目标。 */
    suspend fun migrate(context: Context, from: String, to: String, keep: Boolean) {
        val root = context.filesDir.canonicalPath
        val pending = pendingMigration ?: PendingMigration(root, from, to, keep).also { pendingMigration = it }
        check(pending.root == root && pending.to == to && pending.keep == keep && from in setOf(pending.from, pending.to)) {
            "Finish the interrupted account transition before switching again"
        }
        if (!pending.hasLeft) {
            io.github.nanomuse.focus.FocusStore.pauseOwner(context, pending.from)
            leave(context, pending.from, keep)
            pending.hasLeft = true
        }
        enter(context, to)
    }

    /** 身份发布后刷新任务，再删除已完整恢复的目标备份。 */
    fun completeMigration(context: Context) {
        io.github.nanomuse.feed.FeedFlow.refresh(context)
        pendingMigration?.let { pending ->
            check(key(context) == pending.to) { "Publish the restored account before completing migration" }
            remove(File(context.filesDir, "$STASH/${AccountScope.dirName(pending.to)}"))
            pendingMigration = null
        }
    }

    /** The same, from a coroutine that already runs off the main thread. */
    suspend fun claimNow(context: Context, sessionId: String, owner: String = key(context)) {
        mutations.requireAvailable()
        val dao = SyncDatabase.get(context.applicationContext).dao()
        dao.claimOwners(listOf(SessionOwner(sessionId, owner)))
        check(dao.ownerOf(sessionId) == owner) { "This conversation belongs to another account" }
    }

    /** The sessions owned by [account]. */
    suspend fun sessionsOf(context: Context, account: String): List<String> =
        SyncDatabase.get(context.applicationContext).dao().sessionsOf(account)

    // -- leaving and entering -----------------------------------------------------------------

    /**
     * The account filed under [account] leaves this phone — a sign-out, a switch, *Delete
     * account*, or a key the relay refused. With [keep] its chats stay in the database (hidden
     * by their owner rows until it is back) and its files, preferences and routines are put
     * aside; without, every one of them is deleted. Call it while [account] is still the
     * signed-in key, and inside `ConversationSync.exclusive` so no push sees the chats go.
     */
    // 调用方必须按ConversationSync.exclusive、withTransition顺序持锁。
    suspend fun leave(context: Context, account: String, keep: Boolean) {
        val ctx = context.applicationContext
        reconcileLocked(ctx, account)
        if (!keep) {
            deleteChats(ctx, account)
            deleteTodos(ctx, account)
        }
        val stash = File(ctx.filesDir, "$STASH/${AccountScope.dirName(account)}")
        val pending = pendingMigration
        if (keep) check(stash.isDirectory || stash.mkdirs()) { "Account archive is not writable" }
        else remove(stash)
        for (rel in AccountScope.accountPaths) {
            val src = File(ctx.filesDir, rel)
            if (rel in pending?.departedPaths.orEmpty()) continue
            if (!src.exists()) continue
            if (keep) move(src, File(stash, rel)) else remove(src)
            pending?.departedPaths?.add(rel)
        }
        // the preferences that are the account's: remembered on the side, then gone from the file
        val p = prefs(ctx)
        val mine = p.all.filterKeys { AccountScope.isAccountPref(it) }
        if (keep && pending?.hasSavedPreferences != true) {
            val o = JSONObject()
            for ((k, v) in mine) o.put(k, v)
            File(stash, "prefs.json").writeText(o.toString())
            pending?.hasSavedPreferences = true
        }
        check(p.edit().apply { mine.keys.forEach { remove(it) } }.commit()) { "Account preferences could not be cleared" }
        // the routines: alarms off, the list on the side or gone
        val manager = ScheduledTaskManager(ctx)
        val tasks = manager.list()
        if (keep && pending?.hasSavedRoutines != true) {
            File(stash, "routines.json").writeText(JSONArray().apply { tasks.forEach { put(it.toJson()) } }.toString())
            pending?.hasSavedRoutines = true
        }
        tasks.forEach { manager.delete(it.id) }
        reloadStores(ctx)
        AppLogger.info(TAG, "account left: ${if (keep) "kept aside" else "removed"}")
    }

    /**
     * The account filed under [account] is the signed-in one from now on: what was put aside
     * for it comes back to the fixed paths (nothing, for a first sign-in), the routines are
     * scheduled again, and the stores re-read.
     */
    // 与leave共用已有迁移锁，身份发布在此方法成功返回之后。
    suspend fun enter(context: Context, account: String) {
        val ctx = context.applicationContext
        val stash = File(ctx.filesDir, "$STASH/${AccountScope.dirName(account)}")
        if (stash.isDirectory) {
            for (rel in AccountScope.accountPaths) {
                if (rel in pendingMigration?.restoredPaths.orEmpty()) continue
                val src = File(stash, rel)
                if (!src.exists()) continue
                val dst = File(ctx.filesDir, rel)
                remove(dst)
                copy(src, dst)
                pendingMigration?.restoredPaths?.add(rel)
            }
            run {
                val saved = File(stash, "prefs.json").takeIf { it.exists() }?.let { JSONObject(it.readText()) }
                if (saved != null) {
                    val e = prefs(ctx).edit()
                    for (k in saved.keys()) {
                        when (val v = saved.get(k)) {
                            is Boolean -> e.putBoolean(k, v)
                            is Int -> e.putInt(k, v)
                            is Long -> e.putLong(k, v)
                            is Double -> e.putFloat(k, v.toFloat())
                            else -> e.putString(k, v.toString())
                        }
                    }
                    check(e.commit()) { "Account preferences could not be restored" }
                }
            }
            run {
                val saved = File(stash, "routines.json").takeIf { it.exists() }?.let { JSONArray(it.readText()) }
                if (saved != null) {
                    val manager = ScheduledTaskManager(ctx)
                    for (i in 0 until saved.length()) {
                        val task = ScheduledTask.fromJson(saved.getJSONObject(i))
                        if (manager.get(task.id) == null) manager.create(task) else manager.update(task)
                    }
                }
            }
        }
        reconcileLocked(ctx, account)
        reloadStores(ctx)
    }

    /** `minis-global/nanomuse/accounts/` holds something for [account]. */
    fun hasKept(context: Context, account: String): Boolean =
        File(context.filesDir, "$STASH/${AccountScope.dirName(account)}").isDirectory

    // -- internals ----------------------------------------------------------------------------

    /** 在既有迁移锁中清理账号行，不移动正在打开的Room文件。 */
    private suspend fun deleteTodos(context: Context, owner: String) {
        val database = io.github.nanomuse.mosaic.MosaicDatabase.get(context)
        database.withTransaction {
            val dao = database.todoDao()
            dao.deleteOwnerLinks(owner)
            dao.deleteOwnerDrafts(owner)
            dao.deleteOwnerEvents(owner)
            dao.deleteOwnerOperations(owner)
            dao.deleteOwnerTasks(owner)
            dao.deleteOwnerCategories(owner)
            val focus = database.focusDao()
            focus.deleteLinks(owner); focus.deleteDrafts(owner); focus.deleteOperations(owner)
            focus.deleteSpans(owner); focus.deleteSessions(owner)
        }
        io.github.nanomuse.focus.FocusBackdropStore.deleteOwner(context, owner)
    }

    private suspend fun deleteChats(ctx: Context, account: String) {
        val repo = checkNotNull((ctx as? MinisApp)?.chatRepositoryOrNull) { "Chat storage is unavailable" }
        val dao = SyncDatabase.get(ctx).dao()
        val ids = dao.sessionsOf(account)
        if (ids.isEmpty()) return
        // nanoMuse: 先移除同步映射，避免将本机清理传播成其他设备的聊天删除。
        // 归属逐条保留到完整清理成功；失败直接终止迁移，剩余记录不会被下一账号认领。
        ids.chunked(500).forEach { dao.removeMessagesOfAll(it); dao.removeConversations(it) }
        deleteOwnedChats(ids, deleteChat = { id ->
            repo.dao.deleteMessages(id)
            repo.dao.deleteSession(id)
            io.github.nanomuse.guard.Grants.clearSession(id)
            remove(File(ctx.filesDir, "minis-sessions/$id"))
        }, removeOwner = { id -> dao.removeOwners(listOf(id)) })
        AppLogger.info(TAG, "removed ${ids.size} chat(s) of the account that left")
    }

    private fun move(src: File, dst: File) {
        dst.parentFile?.let { check(it.isDirectory || it.mkdirs()) { "Account directory is not writable" } }
        remove(dst)
        if (src.renameTo(dst)) return
        // 跨文件系统回退必须完整复制并移除源目录，否则保持迁移关闭。
        if (src.isDirectory) src.copyRecursively(dst, overwrite = true) else src.copyTo(dst, overwrite = true)
        remove(src)
    }

    /** 恢复阶段保留源备份，全部元数据与身份提交成功后再清理。 */
    private fun copy(src: File, dst: File) {
        dst.parentFile?.let { check(it.isDirectory || it.mkdirs()) { "Account directory is not writable" } }
        if (src.isDirectory) check(src.copyRecursively(dst, overwrite = true)) { "Account files could not be restored" }
        else src.copyTo(dst, overwrite = true)
    }

    /** 文件未真正移除时不能把当前目录当作新账号的空空间。 */
    private fun remove(file: File) {
        check(!file.exists() || file.deleteRecursively()) { "Account files could not be removed" }
    }

    private fun reloadStores(ctx: Context) {
        io.github.nanomuse.coach.CoachRuntime.reset() // nanoMuse: 移出旧空间后立即清空旧教练引用。
        runCatching { io.github.nanomuse.feed.FeedStore.reload() }
        runCatching { io.github.nanomuse.goals.GoalStore.get(ctx).reload() }
        runCatching { io.github.nanomuse.avatar.AvatarStore.reload() }
        runCatching { io.github.nanomuse.avatar.OwnClip.rescan() }
        runCatching { com.openminis.app.agent.SoulStore.refreshCache(ctx) }
        runCatching { io.github.nanomuse.home.MainChat.reset() }
    }
}
