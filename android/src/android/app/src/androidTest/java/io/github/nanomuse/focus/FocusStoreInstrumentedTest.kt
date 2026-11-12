package io.github.nanomuse.focus

import android.content.Context
import android.os.SystemClock
import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import io.github.nanomuse.account.AccountData
import io.github.nanomuse.coach.CoachTurnAuthorization
import io.github.nanomuse.mosaic.*
import io.github.nanomuse.todo.*
import kotlinx.coroutines.*
import org.junit.*
import org.junit.Assert.*
import org.junit.runner.RunWith
import java.time.*

/** 专注与待办、日记使用隔离内存库，验证事务而不生成真实档案。 */
@RunWith(AndroidJUnit4::class)
class FocusStoreInstrumentedTest {
    private lateinit var context:Context
    private lateinit var db:MosaicDatabase
    private lateinit var store:FocusStore
    private lateinit var todo:TodoStore
    @Before fun prepare() {
        context=ApplicationProvider.getApplicationContext();check(context.packageName.endsWith(".uitest"))
        db=Room.inMemoryDatabaseBuilder(context,MosaicDatabase::class.java).build()
        store=FocusStore(context,db,AccountData.key(context),AccountData.epoch.value)
        todo=TodoStore(context,db,store.ownerKey,store.ownerEpoch)
    }
    @After fun close(){FocusAlarm.schedule(context,null);db.close()}

    @Test fun should_pauseResumeFinish_withoutCompletingLinkedTask()=runBlocking {
        val task=todo.saveTask(TodoTask(ownerKey=store.ownerKey,title="阅读论文",groupName="研究",tagsJson="[\"阅读\"]"),"task")
        val started=store.command("start","start",taskId=task.id)
        db.focusDao().putSession(started.copy(runningElapsed=SystemClock.elapsedRealtime()-5000,runningWall=System.currentTimeMillis()-5000))
        val paused=store.command("pause","pause",started.id,started.revision)
        assertTrue(paused.elapsedMs in 5000..15000);assertEquals("paused",paused.status)
        val frozen=FocusStore.elapsed(paused,context);assertEquals(paused.elapsedMs,frozen)
        val resumed=store.command("resume","resume",paused.id,paused.revision)
        val ended=store.command("finish","finish",resumed.id,resumed.revision)
        assertEquals("finished",ended.status);assertTrue(ended.elapsedMs>=paused.elapsedMs)
        assertEquals("todo",todo.task(task.id)?.status)
        assertEquals("研究",ended.groupName);assertEquals(ended.elapsedMs,store.spans().sumOf { it.durationMs })
    }
    @Test fun should_replayExactly_andRejectConcurrentStartAndOldRevision()=runBlocking {
        val first=store.command("start","same",title="写作")
        assertEquals(first,store.command("start","same",title="写作"))
        assertTrue(runCatching{store.command("start","same",title="不同内容")}.isFailure)
        assertTrue(runCatching{store.command("start","second",title="重叠计时")}.isFailure)
        val paused=store.command("pause","pause",first.id,first.revision)
        assertTrue(runCatching{store.command("finish","stale",first.id,first.revision)}.exceptionOrNull() is TodoConflictException)
        assertEquals(paused,store.sessions().single())
    }
    @Test fun should_capDelayedCountdown_andExcludeBreaks()=runBlocking {
        val first=store.command("start","start",title="到时",minutes=1)
        db.focusDao().putSession(first.copy(runningElapsed=SystemClock.elapsedRealtime()-120000,runningWall=System.currentTimeMillis()-120000))
        val finished=store.sessions().single()
        assertEquals("finished",finished.status);assertEquals(60000L,finished.elapsedMs)
        val rest=store.command("start","rest",title="休息",mode="break",minutes=1)
        db.focusDao().putSession(rest.copy(runningElapsed=SystemClock.elapsedRealtime()-5000))
        store.command("finish","rest-finish",rest.id,rest.revision)
        assertEquals(60000L,store.spans().sumOf { it.durationMs })
    }
    @Test fun should_pauseAfterReboot_withoutInventingTime()=runBlocking {
        val first=store.command("start","start",title="重启前")
        db.focusDao().putSession(first.copy(bootCount=first.bootCount-1,runningElapsed=0))
        val restored=FocusStore(context,db,store.ownerKey,store.ownerEpoch).sessions().single()
        assertEquals("paused",restored.status);assertEquals(0L,restored.elapsedMs)
        assertTrue(store.spans().isEmpty())
    }
    @Test fun should_rejectWrongOwnerEpoch_andKeepAccountsSeparated()=runBlocking {
        store.command("start","start",title="当前账号")
        val other=store.sessions().single().copy(ownerKey="other",id="other",status="finished",endedAt=1)
        db.focusDao().putSession(other)
        assertEquals(1,store.sessions().size)
        val stale=FocusStore(context,db,store.ownerKey,store.ownerEpoch-1)
        assertTrue(runCatching{stale.command("start","wrong",title="不应开始")}.isFailure)
    }
    @Test fun should_linkFinishedSessionsAtomically_andPreserveDeletedSnapshot()=runBlocking {
        val first=store.command("start","start",title="独立阅读")
        val ended=store.command("finish","finish",first.id,first.revision)
        val day=LocalDate.now()
        val draft=MosaicDraft("focus-draft",day.toEpochDay(),null,null,"",null,null,"rounded",.5f,.5f,1f,false,null,"focus-mutation",System.currentTimeMillis())
        val mosaic=MosaicStore(context,db)
        mosaic.putDraftWithTasks(draft,emptyList(),todo,listOf(ended.id),store)
        assertEquals(listOf(ended.id),store.draftLinks(draft.id))
        val saved=checkNotNull(mosaic.saveWithTasks(draft,day,emptyList(),todo,listOf(ended.id),store))
        assertEquals("",saved.text);assertEquals("独立阅读",store.entryLinks(saved.id).single().title)
        store.command("delete","delete",ended.id,ended.revision)
        assertEquals(1,store.entryLinks(saved.id).size);assertTrue(store.sessions().isEmpty())
        val invalid=draft.copy(id="invalid",mutationId="invalid")
        assertTrue(runCatching{mosaic.saveWithTasks(invalid,day,emptyList(),todo,listOf("missing"),store)}.isFailure)
        assertNull(db.dao().entryByMutation("invalid"))
    }
    @Test fun should_rejectFabricatedDurations_andGuardFocusTool()=runBlocking {
        val auth=CoachTurnAuthorization("user","main","token")
        val access=TodoToolAccess(true,true,false,false,"main","user",auth,auth,TodoToolUser("user","开始专注阅读","main"))
        val host=TodoToolHost({access},{_,_->null},{TodoStoreToolStorage(todo)},{store})
        val started=host.execute(FocusAgentBridge.COMMAND,"""{"action":"start","operationId":"tool","title":"阅读","mode":"stopwatch"}""")
        assertTrue(started.output,started.success)
        assertFalse(host.execute(FocusAgentBridge.COMMAND,"""{"action":"start","operationId":"fabricate","title":"假记录","elapsedMs":99999}""").success)
        val denied=TodoToolHost({access.copy(isMain=false)},{_,_->null},{error("not allowed")},{error("not allowed")})
        assertFalse(denied.execute(FocusAgentBridge.QUERY,"{}").success)
    }
}
