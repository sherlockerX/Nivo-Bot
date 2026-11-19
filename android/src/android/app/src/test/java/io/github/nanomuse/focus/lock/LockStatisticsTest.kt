package io.github.nanomuse.focus.lock

import org.junit.Assert.*
import org.junit.Test

/** 强制时长按实际区间切分，退出次数按退出时刻归入统计周期。 */
class LockStatisticsTest {
    private fun run(id:String="r",session:String="s",status:LockRunStatus=LockRunStatus.COMPLETED,ended:Long=2000)=
        LockRun("",id,session,emptySet(),emptySet(),1000,3000,2000,true,0,10,1,status,ended)
    @Test fun should_countMeasuredOverlap_when_sessionCrossesPeriodBoundary() {
        val result=LockStatistics.summarize(listOf(run()),setOf("s"),
            listOf(LockMeasuredSpan("s",1000,2000)),2000,4000)
        assertEquals(1000L,result.durationMs)
        assertEquals(0,result.emergencyCount)
    }
    @Test fun should_excludeOrdinaryOrDeletedSessions_when_calculatingForcedTime() {
        val result=LockStatistics.summarize(listOf(run()),emptySet(),
            listOf(LockMeasuredSpan("s",1000,2000),LockMeasuredSpan("ordinary",1000,5000)),0,10000)
        assertEquals(0L,result.durationMs)
    }
    @Test fun should_countEmergencyOnce_when_exitIsInsidePeriod() {
        val emergency=run(status=LockRunStatus.EMERGENCY)
        assertEquals(1,LockStatistics.summarize(listOf(emergency,emergency),setOf("s"),emptyList(),1000,2001).emergencyCount)
        assertEquals(0,LockStatistics.summarize(listOf(emergency),setOf("s"),emptyList(),1000,2000).emergencyCount)
    }
    @Test fun should_excludeUnfinished_when_settledSpansExist() {
        val active=run(status=LockRunStatus.ACTIVE)
        assertEquals(0L,LockStatistics.summarize(listOf(active),setOf("s"),
            listOf(LockMeasuredSpan("s",1000,2000)),0,10000).durationMs)
    }
}
