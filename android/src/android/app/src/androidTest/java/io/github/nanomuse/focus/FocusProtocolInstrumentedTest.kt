package io.github.nanomuse.focus

import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import android.content.Context
import io.github.nanomuse.account.AccountData
import io.github.nanomuse.mosaic.MosaicDatabase
import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import org.junit.*
import org.junit.Assert.*
import org.junit.runner.RunWith

/** 从实际JSON协议核验手机报告，保留真实调用间隔而不写正式档案。 */
@RunWith(AndroidJUnit4::class)
class FocusProtocolInstrumentedTest {
    private lateinit var context: Context
    private lateinit var database: MosaicDatabase
    private lateinit var store: FocusStore
    private lateinit var bridge: FocusAgentBridge
    @Before fun prepare() {
        context=ApplicationProvider.getApplicationContext()
        check(context.packageName.endsWith(".uitest"))
        database=Room.inMemoryDatabaseBuilder(context,MosaicDatabase::class.java).build()
        store=FocusStore(context,database,AccountData.key(context),AccountData.epoch.value)
        bridge=FocusAgentBridge(store) {}
    }
    @After fun close() { FocusAlarm.schedule(context,null);database.close() }
    @Test fun should_pauseThreeMinuteTimerBeforeDeadline_andQuerySameActiveSession()=runBlocking {
        val start=bridge.execute(FocusAgentBridge.COMMAND,"""{"action":"start","operationId":"start","title":"协议验收","minutes":3}""")
        assertTrue(start.output,start.success)
        val initial=JSONObject(start.output).getJSONObject("data")
        val active=JSONObject(bridge.execute(FocusAgentBridge.QUERY,"""{"kind":"active"}""").output).getJSONObject("data")
        assertEquals(1,active.getInt("total"))
        assertEquals(initial.getString("id"),active.getJSONArray("items").getJSONObject(0).getString("id"))
        val pause=bridge.execute(FocusAgentBridge.COMMAND,JSONObject().put("action","pause").put("operationId","pause")
            .put("targetId",initial.getString("id")).put("expectedRevision",initial.getLong("revision")).toString())
        assertTrue(pause.output,pause.success)
        val paused=JSONObject(pause.output).getJSONObject("data")
        assertEquals("paused",paused.getString("status"))
        assertTrue(paused.toString(),paused.getLong("elapsedMs") in 0..15000)
        assertTrue(paused.isNull("endedAt"))
        val after=JSONObject(bridge.execute(FocusAgentBridge.QUERY,"""{"kind":"active"}""").output).getJSONObject("data")
        assertEquals(1,after.getInt("total"))
        val resume=bridge.execute(FocusAgentBridge.COMMAND,JSONObject().put("action","resume").put("operationId","resume")
            .put("targetId",paused.getString("id")).put("expectedRevision",paused.getLong("revision")).toString())
        assertTrue(resume.output,resume.success)
        assertEquals("running",JSONObject(resume.output).getJSONObject("data").getString("status"))
    }
    @Test fun should_returnFocusLinkAndCurrentTiming_inDetail()=runBlocking {
        val row=store.command("start","start",title="当前时钟")
        val response=JSONObject(bridge.execute(FocusAgentBridge.QUERY,JSONObject().put("kind","detail").put("targetId",row.id).toString()).output)
        assertEquals("minis://views/focus",response.getString("view_url"))
        val detail=response.getJSONObject("data")
        assertTrue(detail.getLong("currentElapsedMs")>=0)
        assertTrue(detail.getLong("remainingMs")<=row.targetMs)
        assertTrue(response.getLong("sampledAt")>=row.startedAt)
    }
    @Test fun should_count38Seconds_notThreeMinutes_andExcludePausedClock()=runBlocking {
        val clock=TestClock()
        val timed=FocusStore(context,database,store.ownerKey,store.ownerEpoch,clock)
        val row=timed.command("start","start",title="精确计时",minutes=3)
        clock.tick(38_072)
        val paused=timed.command("pause","pause",row.id,row.revision)
        assertEquals("paused",paused.status);assertEquals(38_072L,paused.elapsedMs)
        clock.tick(600_000)
        assertEquals(paused,timed.sessions().single())
        val resumed=timed.command("resume","resume",paused.id,paused.revision)
        clock.wallTime-=3_600_000
        clock.tick(2000)
        val finished=timed.command("finish","finish",resumed.id,resumed.revision)
        assertEquals(40_072L,finished.elapsedMs)
    }
    @Test fun should_explainDeadlineReached_andExposeReplayAsOldSnapshot()=runBlocking {
        val clock=TestClock()
        val timed=FocusStore(context,database,store.ownerKey,store.ownerEpoch,clock)
        val protocol=FocusAgentBridge(timed) {}
        val args="""{"action":"start","operationId":"start","title":"到时测试","minutes":3}"""
        val row=JSONObject(protocol.execute(FocusAgentBridge.COMMAND,args).output).getJSONObject("data")
        clock.tick(180_001)
        val paused=JSONObject(protocol.execute(FocusAgentBridge.COMMAND,JSONObject().put("action","pause")
            .put("operationId","pause").put("targetId",row.getString("id")).put("expectedRevision",1).toString()).output).getJSONObject("data")
        assertEquals("deadline_reached",paused.getString("outcome"))
        assertEquals(180_000L,paused.getLong("elapsedMs"))
        val replay=JSONObject(protocol.execute(FocusAgentBridge.COMMAND,args).output).getJSONObject("data")
        assertTrue(replay.getBoolean("isReplaySnapshot"))
        assertFalse(replay.has("currentElapsedMs"))
        assertEquals("finished",replay.getJSONObject("currentState").getString("status"))
        assertEquals(0,JSONObject(protocol.execute(FocusAgentBridge.QUERY,"""{"kind":"active"}""").output).getJSONObject("data").getInt("total"))
    }
    /** 固定开机周期的测试时钟，任意前进无需等待数分钟。 */
    private class TestClock : FocusClockSource {
        var wallTime=System.currentTimeMillis()
        private var monotonic=android.os.SystemClock.elapsedRealtime()
        override fun wall()=wallTime
        override fun elapsed()=monotonic
        override fun boot()=1
        fun tick(ms:Long) { wallTime+=ms;monotonic+=ms }
    }
}
