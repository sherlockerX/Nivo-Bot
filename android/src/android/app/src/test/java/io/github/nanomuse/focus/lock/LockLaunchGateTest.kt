package io.github.nanomuse.focus.lock

import org.junit.Assert.assertFalse
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/** 验证首次拉回、同周期去重、前台身份切换以及有界重试。 */
class LockLaunchGateTest {
    /** 零时刻也必须允许首次拉回。 */
    @Test
    fun should_allowFirstLaunch_when_noAttemptExists() {
        assertTrue(LockLaunchGate().claim(0L))
    }

    /** 尚未聚焦时，不同监测来源仍共享同一次在途尝试。 */
    @Test
    fun should_deduplicatePendingLaunch_when_focusHasNotArrived() {
        val gate = LockLaunchGate()
        gate.observeForeground(1L, false)
        assertTrue(gate.claim(100L))
        for (elapsed in listOf(100L, 350L, 600L, 1599L)) {
            assertFalse(gate.claim(elapsed))
        }
    }

    /** 达到重试边界后重新计时，失败也不能造成无界频繁拉回。 */
    @Test
    fun should_retryAtBoundary_when_previousLaunchDidNotFocus() {
        val gate = LockLaunchGate()
        assertTrue(gate.claim(100L))
        assertTrue(gate.claim(1600L))
        assertFalse(gate.claim(3099L))
        assertTrue(gate.claim(3100L))
    }

    /** 新前台身份不受上一周期节流。 */
    @Test
    fun should_allowImmediately_when_realExternalGenerationChanges() {
        val gate = LockLaunchGate()
        gate.observeForeground(1L, false)
        assertTrue(gate.claim(100L))
        gate.observeForeground(2L, false)
        assertTrue(gate.claim(101L))
    }

    /** 重复扫描不会重新获得启动资格。 */
    @Test
    fun should_keepPendingClaim_when_sameGenerationIsObservedAgain() {
        val gate = LockLaunchGate()
        gate.observeForeground(1L, false)
        assertTrue(gate.claim(100L))
        gate.observeForeground(1L, false)
        assertFalse(gate.claim(101L))
    }

    /** 旧证据既不能清除在途请求，也不能撤销最新焦点。 */
    @Test
    fun should_ignoreStaleEvidence_when_newerGenerationWasObserved() {
        val gate = LockLaunchGate()
        gate.observeForeground(5L, false)
        assertTrue(gate.claim(100L))
        gate.observeForeground(4L, false)
        assertFalse(gate.claim(101L))
        gate.observeForeground(5L, true)
        gate.observeForeground(4L, false)
        assertFalse(gate.claim(5000L))
    }

    /** 已经聚焦时，超过重试期也不重复启动。 */
    @Test
    fun should_suppressOrdinaryLaunch_when_lockUiIsFocused() {
        val gate = LockLaunchGate()
        gate.observeForeground(1L, true)
        assertFalse(gate.claim(100L))
        assertFalse(gate.claim(5000L))
    }

    /** 单独失焦不代表出现新的外部前台身份。 */
    @Test
    fun should_keepPendingClaim_when_sameGenerationLosesFocus() {
        val gate = LockLaunchGate()
        gate.observeForeground(1L, false)
        assertTrue(gate.claim(100L))
        gate.observeForeground(1L, true)
        gate.observeForeground(1L, false)
        assertFalse(gate.claim(101L))
    }

    /** 真实切出锁页必须立即恢复拉回能力。 */
    @Test
    fun should_allowNewExit_when_previousCycleHadFocusedLockUi() {
        val gate = LockLaunchGate()
        gate.observeForeground(1L, true)
        assertFalse(gate.claim(100L))
        gate.observeForeground(2L, false)
        assertTrue(gate.claim(101L))
    }

    /** 点亮屏幕可越过焦点限制，但不能绕过去重。 */
    @Test
    fun should_deduplicateWakeRequests_when_lockUiIsAlreadyFocused() {
        val gate = LockLaunchGate()
        gate.observeForeground(1L, true)
        assertTrue(gate.claim(100L, true))
        assertFalse(gate.claim(101L, true))
        assertTrue(gate.claim(1600L, true))
    }

    /** 被焦点规则拒绝的普通请求不消耗点亮屏幕资格。 */
    @Test
    fun should_keepWakeClaimAvailable_when_ordinaryFocusedRequestWasRejected() {
        val gate = LockLaunchGate()
        gate.observeForeground(1L, true)
        assertFalse(gate.claim(100L))
        assertTrue(gate.claim(100L, true))
    }

    /** 普通请求与点亮屏幕共享同一次在途尝试。 */
    @Test
    fun should_shareAttemptWindow_when_wakeRequestFollowsOrdinaryLaunch() {
        val gate = LockLaunchGate()
        assertTrue(gate.claim(100L))
        assertFalse(gate.claim(101L, true))
    }

    /** 宿主确认时钟基线失效后显式重置，不将任意迟到采样当作重启。 */
    @Test
    fun should_rebaseline_when_hostExplicitlyResetsAfterClockChange() {
        val gate = LockLaunchGate()
        assertTrue(gate.claim(5000L))
        gate.reset()
        assertTrue(gate.claim(100L))
        assertFalse(gate.claim(101L))
        assertTrue(gate.claim(1600L))
    }

    /** 先采样的线程可能后获得锁，较旧时间戳不能清除在途请求。 */
    @Test
    fun should_keepPendingClaim_when_concurrentSamplesArriveOutOfOrder() {
        val gate = LockLaunchGate()
        gate.observeForeground(1L, false)
        assertTrue(gate.claim(101L))
        assertFalse(gate.claim(100L))
        assertFalse(gate.claim(1600L))
        assertTrue(gate.claim(1601L))
    }

    /** 会话重置清除代数、焦点和在途限制。 */
    @Test
    fun should_clearAllState_when_sessionResets() {
        val gate = LockLaunchGate()
        gate.observeForeground(100L, true)
        assertTrue(gate.claim(100L, true))
        gate.reset()
        gate.observeForeground(1L, false)
        assertTrue(gate.claim(101L))
    }

    /** 自定义间隔也采用包含边界的比较。 */
    @Test
    fun should_useConfiguredInterval_when_retryDurationDiffers() {
        val gate = LockLaunchGate(200L)
        assertTrue(gate.claim(0L))
        assertFalse(gate.claim(199L))
        assertTrue(gate.claim(200L))
    }

    /** 零间隔会失去节流保护。 */
    @Test(expected = IllegalArgumentException::class)
    fun should_rejectInvalidConfiguration_when_retryIntervalIsZero() {
        LockLaunchGate(0L)
    }

    /** 负间隔不能构造门控。 */
    @Test(expected = IllegalArgumentException::class)
    fun should_rejectInvalidConfiguration_when_retryIntervalIsNegative() {
        LockLaunchGate(-1L)
    }

    /** 非法单调时刻必须显式拒绝。 */
    @Test(expected = IllegalArgumentException::class)
    fun should_rejectInvalidTime_when_elapsedTimeIsNegative() {
        LockLaunchGate().claim(-1L)
    }

    /** 焦点抑制不能掩盖调用方传入的非法时间。 */
    @Test(expected = IllegalArgumentException::class)
    fun should_rejectInvalidTime_when_focusedClaimHasNegativeElapsedTime() {
        val gate = LockLaunchGate()
        gate.observeForeground(1L, true)
        gate.claim(Long.MIN_VALUE)
    }

    /** 接近最大时刻时仍按差值节流，避免截止时刻加法溢出。 */
    @Test
    fun should_keepPendingClaim_when_elapsedTimeApproachesLongMaximum() {
        val gate = LockLaunchGate()
        assertTrue(gate.claim(Long.MAX_VALUE - 100L))
        assertFalse(gate.claim(Long.MAX_VALUE))
    }

    /** 多个监测线程同时申请也只能产生一次在途拉回。 */
    @Test
    fun should_allowExactlyOneClaim_when_multipleThreadsRequestSameCycle() {
        val gate = LockLaunchGate()
        val workerCount = 8
        val workers = Executors.newFixedThreadPool(workerCount)
        val ready = CountDownLatch(workerCount)
        val start = CountDownLatch(1)
        try {
            val claims = (1..workerCount).map {
                workers.submit<Boolean> {
                    ready.countDown()
                    check(start.await(5L, TimeUnit.SECONDS))
                    gate.claim(100L)
                }
            }
            assertTrue(ready.await(5L, TimeUnit.SECONDS))
            start.countDown()
            assertEquals(1, claims.count { it.get(5L, TimeUnit.SECONDS) })
        } finally {
            start.countDown()
            workers.shutdownNow()
        }
    }

    /** 重置之后即使没有新的前台观察也必须清除旧焦点和旧尝试。 */
    @Test
    fun should_allowFreshClaim_when_resetHasNoFollowingForegroundObservation() {
        val gate = LockLaunchGate()
        gate.observeForeground(1L, true)
        assertTrue(gate.claim(100L, true))
        gate.reset()
        assertTrue(gate.claim(101L))
    }
}
