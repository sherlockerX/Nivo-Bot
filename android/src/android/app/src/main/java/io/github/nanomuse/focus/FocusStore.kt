package io.github.nanomuse.focus

import android.content.Context
import android.os.SystemClock
import android.provider.Settings
import androidx.room.withTransaction
import io.github.nanomuse.account.AccountData
import io.github.nanomuse.mosaic.MosaicDatabase
import io.github.nanomuse.todo.TodoConflictException
import kotlinx.coroutines.flow.combine
import org.json.JSONObject
import java.util.UUID

/** 与待办共享账号锁及Room事务，计时不依赖页面生命周期。 */
class FocusStore internal constructor(private val context: Context, internal val database: MosaicDatabase,
    val ownerKey: String, val ownerEpoch: Long, private val clock: FocusClockSource = DeviceFocusClock(context)) {
    internal val dao = database.focusDao()
    internal val appContext:Context get()=context
    /** 页面流在账号切换后立即隐藏旧身份记录。 */
    fun observe() = combine(dao.observe(ownerKey), AccountData.epoch) { rows, epoch ->
        if (epoch == ownerEpoch && AccountData.key(context) == ownerKey) rows else emptyList()
    }
    /** 日记关联流沿用账号代次边界。 */
    fun observeEntryLinks(id:String)=combine(dao.observeEntryLinks(ownerKey,id),AccountData.epoch) { rows,epoch ->
        if(epoch==ownerEpoch && AccountData.key(context)==ownerKey) rows else emptyList()
    }
    /** 查询前结算已到时或重启后需要暂停的计时。 */
    suspend fun sessions(): List<FocusSession> = transaction { reconcile(); dao.sessions(ownerKey) }
    /** 导出完整计时与区间供个人备份，活动计时以导出时的已提交状态记录。 */
    suspend fun exportJson():String = transaction {
        reconcile()
        val sessions=dao.sessions(ownerKey)
        val ids=sessions.map { it.id }.toSet()
        org.json.JSONObject().put("format","nanomuse-focus").put("version",1)
            .put("sessions",org.json.JSONArray(sessions.map(FocusJson::session)))
            .put("spans",org.json.JSONArray(dao.allSpans(ownerKey).filter { it.sessionId in ids }.map {
                org.json.JSONObject().put("id",it.id).put("sessionId",it.sessionId).put("startedAt",it.startedAt).put("durationMs",it.durationMs)
            })).toString(2)
    }
    /** 统计只读取已结束且未删除的专注区间。 */
    suspend fun spans(): List<FocusSpan> = transaction { dao.spans(ownerKey) }
    /** 读取日记保存的专注快照。 */
    suspend fun entryLinks(id: String): List<FocusEntryLink> = transaction { dao.entryLinks(ownerKey,id) }
    /** 恢复未提交的日记时段选择。 */
    suspend fun draftLinks(id: String): List<String> = transaction { dao.draftLinks(ownerKey,id).map { it.sessionId } }
    /** 结算到时记录并更新当前账号的提醒。 */
    suspend fun refresh(): FocusSession? = transaction {
        val active=reconcile()
        try { FocusAlarm.schedule(context,active) } catch(_:SecurityException) { /* 没有通知能力仍保留真实计时。 */ }
        active
    }

    /** 控制命令只接受配置及目标ID，实际时长始终由设备计量。 */
    suspend fun command(action: String, operationId: String, targetId: String? = null, expectedRevision: Long? = null,
        title: String = "", taskId: String? = null, mode: String = "pomodoro", minutes: Int = 25,
        authorize: suspend () -> Unit = {}): FocusSession {
        require(operationId.matches(Regex("[A-Za-z0-9_.:-]{1,160}"))) { "Invalid operationId" }
        require(action in setOf("start","pause","resume","finish","delete")) { "Unknown action" }
        val request = JSONObject().put("action",action).put("targetId",targetId ?: "").put("revision",expectedRevision ?: -1)
            .put("title",title).put("taskId",taskId ?: "").put("mode",mode).put("minutes",minutes).toString()
        val result = transaction {
            authorize()
            val previous = dao.operation(ownerKey,operationId)
            if (previous != null) {
                require(previous.request == request) { "operation_id_conflict" }
                FocusJson.read(ownerKey,previous.result)
            } else {
                val row = if (action == "start") start(title,taskId,mode,minutes) else mutate(action,targetId,expectedRevision)
                dao.putOperation(FocusOperation(ownerKey,operationId,request,FocusJson.session(row).toString()))
                authorize()
                row
            }
        }
        // 通知调度失败不抹掉已提交的计时事实，下次打开页面仍可恢复。
        try { refresh() } catch(cancelled:kotlinx.coroutines.CancellationException) { throw cancelled } catch(_:Exception) { }
        return result
    }

    private suspend fun start(title: String, taskId: String?, mode: String, minutes: Int): FocusSession {
        require(mode in setOf("pomodoro","stopwatch","break")) { "Invalid timer mode" }
        require(minutes in 1..180) { "Duration must be 1..180 minutes" }
        reconcile()
        check(dao.active(ownerKey) == null) { "active_session_exists" }
        val task = taskId?.let { database.todoDao().task(ownerKey,it)?.takeIf { row -> row.deletedAt == null }
            ?: error("task_not_found") }
        val name = (task?.title ?: title).trim()
        require(name.isNotEmpty() && name.length <= 500) { "A focus title is required" }
        val wall=clock.wall()
        val row=FocusSession(ownerKey,UUID.randomUUID().toString(),name,task?.id,task?.groupName.orEmpty(),task?.tagsJson ?: "[]",
            mode,if(mode == "stopwatch") MAX_SESSION_MS else minutes*60_000L,startedAt=wall,updatedAt=wall,
            runningWall=wall,runningElapsed=clock.elapsed(),bootCount=clock.boot())
        dao.putSession(row)
        return row
    }

    private suspend fun mutate(action: String,id: String?,revision: Long?): FocusSession {
        val old = id?.let { dao.session(ownerKey,it) }?.takeIf { it.deletedAt == null } ?: error("focus_not_found")
        require(revision != null) { "expectedRevision is required" }
        if (old.revision != revision) throw TodoConflictException("Focus changed; query again",taskId=old.id,expectedRevision=revision,actualRevision=old.revision)
        val now=clock.wall()
        val settled=settle(old)
        val row=when(action) {
            "pause" -> { check(old.status == "running") { "not_running" }; settled.copy(status=if(settled.status == "finished") "finished" else "paused") }
            "resume" -> { check(old.status == "paused") { "not_paused" }; settled.copy(status="running",runningWall=now,runningElapsed=clock.elapsed(),bootCount=clock.boot()) }
            "finish" -> { check(old.status in setOf("running","paused","finished")) { "not_active" }; settled.copy(status="finished",endedAt=settled.endedAt ?: now) }
            else -> { check(old.status == "finished") { "finish_before_delete" }; settled.copy(deletedAt=now) }
        }.copy(revision=old.revision+1,updatedAt=now)
        dao.putSession(row)
        return row
    }

    /** 只在边界提交区间，避免每秒写盘；重启后的未知时段不计入。 */
    private suspend fun settle(row: FocusSession): FocusSession {
        if(row.status != "running") return row
        val currentBoot=clock.boot()
        val delta=FocusTiming.delta(row.runningElapsed,clock.elapsed(),row.bootCount==currentBoot,row.targetMs-row.elapsedMs)
        if(delta>0) dao.putSpan(FocusSpan(ownerKey,UUID.randomUUID().toString(),row.id,row.runningWall,delta))
        val total=row.elapsedMs+delta
        val done=total>=row.targetMs
        return row.copy(elapsedMs=total,status=if(done) "finished" else "paused",
            endedAt=if(done) row.runningWall+delta else null,runningElapsed=clock.elapsed(),runningWall=clock.wall(),bootCount=currentBoot)
    }

    private suspend fun reconcile(): FocusSession? {
        val row=dao.active(ownerKey) ?: return null
        if(row.status != "running") return row
        val sameBoot=row.bootCount==clock.boot()
        val duration=currentElapsed(row)
        if(sameBoot && duration<row.targetMs) return row
        val saved=settle(row).copy(revision=row.revision+1,updatedAt=clock.wall())
        dao.putSession(saved)
        return saved.takeIf { it.status != "finished" }
    }

    /** 查询采用与结算一致的设备时钟，测试可注入固定时间而不伪造数据库。 */
    internal fun currentElapsed(row: FocusSession): Long = row.elapsedMs + if (row.status == "running")
        FocusTiming.delta(row.runningElapsed, clock.elapsed(), row.bootCount == clock.boot(), row.targetMs - row.elapsedMs) else 0

    /** 自动保存关联只验证既有记录，不生成专注事实。调用者已持账号与数据库锁。 */
    internal suspend fun putDraftInTransaction(draftId: String, ids: List<String>) {
        require(ids.size<=100 && ids.distinct().size==ids.size) { "Invalid focus selection" }
        val entryId=database.dao().draft(draftId)?.entryId
        val old=entryId?.let { dao.entryLinks(ownerKey,it).map { row -> row.sessionId }.toSet() }.orEmpty()
        ids.forEach { if(it !in old) requireFinished(it) }
        dao.clearDraftLinks(ownerKey,draftId)
        dao.putDraftLinks(ids.map { FocusDraftLink(ownerKey,draftId,it) })
    }

    internal suspend fun saveEntryInTransaction(entryId: String,draftId: String,ids: List<String>) {
        require(ids.size<=100 && ids.distinct().size==ids.size)
        val old=dao.entryLinks(ownerKey,entryId).associateBy { it.sessionId }
        val links=ids.map { id -> old[id] ?: requireFinished(id).let { row ->
            FocusEntryLink(ownerKey,entryId,id,row.title,row.startedAt,checkNotNull(row.endedAt),row.elapsedMs) } }
        dao.clearEntryLinks(ownerKey,entryId);dao.putEntryLinks(links);dao.clearDraftLinks(ownerKey,draftId)
    }
    private suspend fun requireFinished(id: String): FocusSession = checkNotNull(dao.session(ownerKey,id)?.takeIf {
        it.deletedAt==null && it.status=="finished" && it.mode!="break" }) { "focus_not_finished" }
    internal suspend fun <T> transaction(block:suspend ()->T):T = AccountData.withTodoOwnerMutation(ownerKey,ownerEpoch) { database.withTransaction(block) }

    companion object {
        const val MAX_SESSION_MS=12*60*60*1000L
        /** 捕获当前可用账号，之后不允许跨代次写入。 */
        fun get(context:Context):FocusStore { AccountData.requireAvailable();return FocusStore(context.applicationContext,MosaicDatabase.get(context),AccountData.key(context),AccountData.epoch.value) }
        /** 系统开机序号用于拒绝跨重启的单调时间推算。 */
        fun boot(context:Context):Int=Settings.Global.getInt(context.contentResolver,Settings.Global.BOOT_COUNT,-1)
        /** 仅用于展示，持久化由事务边界完成。 */
        fun elapsed(row:FocusSession,context:Context):Long=row.elapsedMs+if(row.status=="running")
            FocusTiming.delta(row.runningElapsed,SystemClock.elapsedRealtime(),row.bootCount==boot(context),row.targetMs-row.elapsedMs) else 0

        /** 已持账号迁移锁时暂停旧账号，不能让后台计时跨身份延续。 */
        suspend fun pauseOwner(context:Context,owner:String) {
            val store=FocusStore(context,MosaicDatabase.get(context),owner,AccountData.epoch.value)
            store.database.withTransaction {
                store.dao.active(owner)?.takeIf { it.status=="running" }?.let { row ->
                    store.dao.putSession(store.settle(row).copy(revision=row.revision+1,updatedAt=System.currentTimeMillis()))
                }
            }
            FocusAlarm.schedule(context,null)
        }
    }
}
