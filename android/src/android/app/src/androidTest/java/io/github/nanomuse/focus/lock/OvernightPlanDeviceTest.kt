package io.github.nanomuse.focus.lock

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.time.ZoneId
import java.time.ZonedDateTime
import java.util.UUID

/**
 * 用真实时钟走一遍跨午夜计划：昨天开始、今天结束的时段要在结束时刻解锁，之后不能再锁上。
 * 本地时间须早于20:57，计划为昨晚21点到几分钟之后；其他时刻跳过。
 */
@RunWith(AndroidJUnit4::class)
class OvernightPlanDeviceTest {
    private val context = ApplicationProvider.getApplicationContext<Context>()

    @Test fun should_unlockAtPlanEnd_when_planCrossesMidnight() = runBlocking {
        val zone = ZoneId.systemDefault()
        val now = ZonedDateTime.now(zone)
        val nowMinute = now.hour * 60 + now.minute
        // 与用户的计划同形：昨晚21点开始，今天几分钟后结束，跨过午夜。
        val start = 21 * 60
        val end = nowMinute + 3
        assumeTrue("needs local time before 20:57", end < start)
        // 测试进程重启后，无障碍服务要等系统重新绑定才算连接。
        val waitUntil = System.currentTimeMillis() + 30_000
        while (!LockPermissions.read(context).isReady && System.currentTimeMillis() < waitUntil) delay(500)
        assumeTrue("forced focus permissions must be granted", LockPermissions.read(context).isReady)
        val store = LockStore.get(context)
        assumeTrue("no other lock may be active", store.active() == null)
        val expectedEnd = now.toLocalDate().atTime(end / 60, end % 60).atZone(zone).toInstant().toEpochMilli()
        val plan = store.savePlan(LockPlan(UUID.randomUUID().toString(), "overnight-device-test", days = (1..7).toSet(),
            ranges = listOf(TimeRange(start, end)), ownerKey = store.ownerKey))
        try {
            val run = LockController.evaluate(context)
            assertNotNull("the plan did not start", run)
            // 开始时刻在计划判定之后才取，截止会晚几十毫秒。
            assertTrue("yesterday's occurrence must end at today's end minute",
                kotlin.math.abs(run!!.deadlineAt - expectedEnd) < 2_000)
            while (System.currentTimeMillis() < run.deadlineAt + 5_000) delay(1_000)
            assertNull("still locked after the plan ended", LockController.evaluate(context))
            assertNull(store.active())
            assertNull("the guard still holds a snapshot", LockRuntime.state.value)
            assertEquals(false, LockController.isGuardActive(context))
            assertEquals(LockRunStatus.COMPLETED, store.runs().first { it.id == run.id }.status)
            // 结束后一分钟内反复评估，不能被同一计划重新锁上。
            repeat(12) {
                delay(5_000)
                assertNull("re-locked after the plan ended", LockController.evaluate(context))
            }
        } finally {
            runCatching { store.deletePlan(plan.id, plan.revision) }
        }
    }
}
