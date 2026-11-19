package io.github.nanomuse.focus.lock

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** 验证生命周期重放与旧使用记录不会覆盖更新的可信前台证据。 */
class ForegroundEvidenceTest {
    /** 暂停或停止都会清除同一Activity，重复查询的旧恢复事件不能将它复活。 */
    @Test
    fun should_clearPreviousActivity_when_matchingPauseOrStopArrives() {
        for (endType in listOf(ForegroundLifecycle.PAUSED, ForegroundLifecycle.STOPPED)) {
            val tracker = UsageForegroundTracker()
            tracker.accept(ForegroundLifecycle.RESUMED, "video", "video.Main", 100L)
            tracker.accept(endType, "video", "video.Main", 200L)
            assertNull(tracker.current)
            tracker.accept(ForegroundLifecycle.RESUMED, "video", "video.Main", 100L)
            assertNull(tracker.current)
        }
    }

    /** 同毫秒恢复和暂停在后续重放时也不能让已退出的Activity重新占据前台。 */
    @Test
    fun should_ignoreReplayedResume_when_pauseHasSameTimestamp() {
        val tracker = UsageForegroundTracker()
        tracker.accept(ForegroundLifecycle.RESUMED, "video", "video.Main", 100L)
        tracker.accept(ForegroundLifecycle.PAUSED, "video", "video.Main", 100L)
        tracker.accept(ForegroundLifecycle.RESUMED, "video", "video.Main", 100L)
        assertNull(tracker.current)
    }

    /** 同一毫秒的不同Activity仍按实际事件顺序切换，重放前一个事件不倒退。 */
    @Test
    fun should_keepLatestActivity_when_sameTimestampEventsAreReplayed() {
        val tracker = UsageForegroundTracker()
        tracker.accept(ForegroundLifecycle.RESUMED, "video", "video.Main", 100L)
        tracker.accept(ForegroundLifecycle.RESUMED, "study", "study.Main", 100L)
        tracker.accept(ForegroundLifecycle.RESUMED, "video", "video.Main", 100L)
        assertEquals("study", tracker.current?.packageName)
    }

    /** 旧Activity的停止事件不能清除已经显示的新白名单Activity。 */
    @Test
    fun should_keepNewForeground_when_otherActivityStops() {
        val tracker = UsageForegroundTracker()
        tracker.accept(ForegroundLifecycle.RESUMED, "video", "video.Main", 100L)
        tracker.accept(ForegroundLifecycle.RESUMED, "study", "study.Main", 200L)
        tracker.accept(ForegroundLifecycle.STOPPED, "video", "video.Main", 300L)
        assertEquals("study", tracker.current?.packageName)
    }

    /** 同包不同Activity的迟到停止事件不能误清新界面。 */
    @Test
    fun should_keepNewClass_when_oldClassInSamePackagePauses() {
        val tracker = UsageForegroundTracker()
        tracker.accept(ForegroundLifecycle.RESUMED, "own", "own.Main", 100L)
        tracker.accept(ForegroundLifecycle.RESUMED, "own", "own.Lock", 200L)
        tracker.accept(ForegroundLifecycle.PAUSED, "own", "own.Main", 300L)
        assertEquals("own.Lock", tracker.current?.className)
    }

    /** 真正再次恢复的较新事件能够重新建立前台，不因旧暂停永久失效。 */
    @Test
    fun should_acceptNewResume_when_activityReturnsAfterPause() {
        val tracker = UsageForegroundTracker()
        tracker.accept(ForegroundLifecycle.RESUMED, "video", "video.Main", 100L)
        tracker.accept(ForegroundLifecycle.PAUSED, "video", "video.Main", 200L)
        tracker.accept(ForegroundLifecycle.RESUMED, "video", "video.Main", 300L)
        assertEquals(300L, tracker.current?.timestamp)
    }

    /** 没有离开事件时不按固定时长抛弃仍在前台的禁用应用。 */
    @Test
    fun should_keepCurrentActivity_when_noContradictingLifecycleExists() {
        val tracker = UsageForegroundTracker()
        tracker.accept(ForegroundLifecycle.RESUMED, "video", "video.Main", 100L)
        tracker.accept(ForegroundLifecycle.STOPPED, "other", "other.Main", 10_000L)
        assertEquals(100L, tracker.current?.timestamp)
    }

    /** 新会话或时钟重建时允许更小的时间戳，不携带旧水位。 */
    @Test
    fun should_acceptFreshBaseline_when_trackerIsReset() {
        val tracker = UsageForegroundTracker()
        tracker.accept(ForegroundLifecycle.RESUMED, "video", "video.Main", 5000L)
        tracker.reset()
        assertNull(tracker.current)
        tracker.accept(ForegroundLifecycle.RESUMED, "study", "study.Main", 100L)
        assertEquals("study", tracker.current?.packageName)
    }

    /** 无效包名不能推进时间水位或替换有效前台。 */
    @Test
    fun should_ignoreMissingPackage_when_eventHasNoIdentity() {
        val tracker = UsageForegroundTracker()
        tracker.accept(ForegroundLifecycle.RESUMED, null, null, 5000L)
        tracker.accept(ForegroundLifecycle.RESUMED, " ", null, 5000L)
        tracker.accept(ForegroundLifecycle.RESUMED, "study", "study.Main", 100L)
        assertEquals("study", tracker.current?.packageName)
    }

    /** 查询中即使切出后又回到同包，代数变化也必须使旧查询失效。 */
    @Test
    fun should_rejectQueryResult_when_foregroundGenerationChanged() {
        assertFalse(canUse(activity(300L), queriedGeneration = 1L, observedGeneration = 3L))
    }

    /** 查询开始前已经显示的白名单页面，也不能被更旧禁用记录抢走。 */
    @Test
    fun should_rejectOldBlockedActivity_when_newerWhitelistObservationExists() {
        assertFalse(canUse(activity(100L), observedPackage = "study", observedWall = 200L))
    }

    /** 电话的新观察同样优先，避免旧禁用记录打断电话界面。 */
    @Test
    fun should_rejectOldBlockedActivity_when_newerPhoneObservationExists() {
        assertFalse(canUse(activity(100L), observedPackage = "dialer", observedWall = 200L))
    }

    /** 包名相同但Activity身份不同，也属于已被新观察推翻的旧证据。 */
    @Test
    fun should_rejectOldClass_when_newerClassInSamePackageIsObserved() {
        assertFalse(canUse(ForegroundActivity("own", "own.Main", 100L),
            observedPackage = "own", observedClass = "own.Lock", observedWall = 200L))
    }

    /** 同毫秒冲突没有可靠先后顺序，保守保留当前可靠前台观察。 */
    @Test
    fun should_rejectConflictingTie_when_timestampsAreEqual() {
        assertFalse(canUse(activity(200L), observedPackage = "study", observedWall = 200L))
    }

    /** 使用记录确实更新时，仍能补偿遗漏的无障碍切出事件。 */
    @Test
    fun should_acceptNewerUsageActivity_when_observationIsOlder() {
        assertTrue(canUse(activity(300L), observedPackage = "study", observedWall = 200L))
    }

    /** 时间较旧但身份一致时可继续有界重试，不按年龄直接放开禁用应用。 */
    @Test
    fun should_acceptConsistentIdentity_when_usageTimestampIsOld() {
        assertTrue(canUse(activity(100L), observedWall = 10_000L))
    }

    /** 没有可靠前台观察时，不虚构矛盾来禁用备用监测。 */
    @Test
    fun should_acceptUsageEvidence_when_observedPackageIsMissing() {
        assertTrue(canUse(activity(100L), observedPackage = null, observedWall = 200L))
    }

    /** 缺少类名不是已证实的同包身份冲突，包名一致时保留备用证据。 */
    @Test
    fun should_acceptSamePackage_when_oneClassNameIsUnknown() {
        assertTrue(canUse(activity(100L), observedClass = null, observedWall = 200L))
        assertTrue(canUse(ForegroundActivity("video", null, 100L), observedWall = 200L))
    }

    private fun activity(timestamp: Long) = ForegroundActivity("video", "video.Main", timestamp)

    private fun canUse(
        activity: ForegroundActivity,
        queriedGeneration: Long = 1L,
        observedGeneration: Long = 1L,
        observedPackage: String? = "video",
        observedClass: String? = "video.Main",
        observedWall: Long = 0L
    ): Boolean = ForegroundEvidencePolicy.canUse(activity, queriedGeneration, observedGeneration,
        observedPackage, observedClass, observedWall)
}
