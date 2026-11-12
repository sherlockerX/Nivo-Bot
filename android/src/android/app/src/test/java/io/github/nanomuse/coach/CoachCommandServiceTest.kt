package io.github.nanomuse.coach

import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/** 验证跨入口写入、证据门槛与磁盘恢复。 */
class CoachCommandServiceTest {
    @get:Rule val folder = TemporaryFolder()
    private val course = CoachCourse("expression", "表达", "会客厅", CoachKind.EXPRESSION,
        listOf(CoachUnit("1.1", "先问再答", "先确认关切", "对话重试",
            listOf(CoachCriterion("target", "先确认关切")), "自拟练习")), "v1", "self_authored")

    private fun service() = CoachCommandService(CoachFileStore(folder.newFolder()), listOf(course))
    private fun run(service: CoachCommandService, action: String, target: String = "expression",
        text: String = "", payload: String = "", op: String = java.util.UUID.randomUUID().toString(),
        user: CoachUserInput? = null) = service.execute(CoachCommand(action, op,
            service.state.value.revision, target, text, if (action == "coach_reply" && payload.isNotBlank()) org.json.JSONObject(payload).put("requestTurnId", service.state.value.sessions.find { it.id == target }?.pendingTurnId ?: "").toString() else payload), user)

    @Test fun should_keep_one_session_when_start_is_retried() {
        val service = service()
        val command = CoachCommand("start", "same", 0, "expression")
        assertTrue(service.execute(command).success)
        assertTrue(service.execute(command).success)
        assertEquals(1, service.state.value.sessions.size)
        assertEquals(1, service.state.value.revision)
    }

    @Test fun should_reject_stale_mutation_without_losing_draft() {
        val service = service()
        run(service, "start")
        val session = service.state.value.sessions.single()
        run(service, "save_input", session.id, "尚未发送")
        assertFalse(service.execute(CoachCommand("save_input", "old", 0, session.id, "旧内容")).success)
        assertEquals("尚未发送", service.state.value.sessions.single().draft)
    }

    @Test fun should_reject_invented_evidence_and_preserve_first_answer() {
        val service = service()
        run(service, "start")
        val id = service.state.value.sessions.single().id
        run(service, "coach_reply", id, "室友说实验又失败了。你怎么回应？", "{\"next\":\"first\"}")
        run(service, "answer", id, "你最担心哪一步？", user = CoachUserInput("u1", "你最担心哪一步？"))
        val turn = service.state.value.sessions.single().turns.last()
        val result = run(service, "coach_reply", id, "表现很好", """{"next":"probe","evidence":[{"criterionId":"target","turnId":"${turn.id}","quote":"伪造原文","reason":"臆测","met":true}]}""")
        assertFalse(result.success)
        assertEquals("你最担心哪一步？", service.state.value.sessions.single().turns.last().text)
        assertTrue(service.state.value.tracks.single().demonstrated.isEmpty())
    }

    @Test fun should_not_accept_ordinary_chat_as_training_answer() {
        val service = service()
        run(service, "start")
        val id = service.state.value.sessions.single().id
        run(service, "coach_reply", id, "你会怎样说？", "{\"next\":\"first\"}")
        assertFalse(run(service, "answer", id, "假装答题", user = CoachUserInput("weather", "帮我查天气")).success)
        assertNull(service.state.value.sessions.single().pendingTurnId)
    }

    @Test fun should_restore_committed_state_after_restart() {
        val dir = folder.newFolder()
        val first = CoachCommandService(CoachFileStore(dir), listOf(course))
        run(first, "pause_course")
        val restored = CoachCommandService(CoachFileStore(dir), listOf(course))
        assertTrue(restored.state.value.tracks.single().paused)
        assertEquals(first.state.value.revision, restored.state.value.revision)
    }

    @Test fun should_not_overwrite_both_corrupt_snapshots_with_defaults() {
        val dir = folder.newFolder()
        java.io.File(dir, "state.json").writeText("broken")
        java.io.File(dir, "state.backup.json").writeText("broken too")
        assertThrows(IllegalStateException::class.java) { CoachCommandService(CoachFileStore(dir), listOf(course)) }
        assertEquals("broken", java.io.File(dir, "state.json").readText())
    }

    @Test fun should_upgradeBundledCriteria_withoutRewritingOldSessionEvidence() {
        val dir = folder.newFolder()
        val original = course.copy(source = "original built-in source", version = "legacy-v1")
        val turn = CoachTurn("first", "user", "保留我的第一次回答", "first")
        val oldSession = CoachSession("old", original, "1.1", status = "active", stage = "first",
            turns = listOf(turn), pendingTurnId = turn.id)
        CoachFileStore(dir).save(CoachState(revision = 8,
            tracks = listOf(CoachTrack(original, demonstrated = setOf("1.1"))), sessions = listOf(oldSession),
            actions = listOf(CoachAction("old-action", "old", "旧现实任务"))))
        val updated = original.copy(version = "coach-curriculum-v3+new", importProtocol = "coach-curriculum-v3",
            builtInSourceId = "expression", units = original.units.map { unit -> unit.copy(
                criteria = unit.criteria.map { it.copy(requiresRealAction = true) }) })
        val service = CoachCommandService(CoachFileStore(dir), listOf(updated))
        val state = service.state.value
        assertEquals(updated, state.tracks.single().course)
        assertTrue(state.tracks.single().demonstrated.isEmpty())
        assertEquals(original, state.sessions.single().course)
        assertEquals(listOf(turn), state.sessions.single().turns)
        assertTrue(state.sessions.single().requiresCourseReview)
        assertEquals("paused", state.sessions.single().status)
        assertFalse(run(service, "resume_session", oldSession.id).success)
        assertFalse(run(service, "coach_reply", oldSession.id, "旧标准通过", "{\"next\":\"probe\"}").success)
        assertFalse(run(service, "action_report", "old-action", "实际完成旧任务",
            user = CoachUserInput("report", "实际完成旧任务")).success)
        assertTrue(run(service, "start").success)
        assertEquals(2, service.state.value.sessions.size)
        assertEquals(updated, service.state.value.sessions.last().course)
        assertEquals("保留我的第一次回答", service.state.value.sessions.first().turns.single().text)
        val restored = CoachCommandService(CoachFileStore(dir), listOf(updated))
        assertEquals(service.state.value, restored.state.value)
    }

    @Test fun should_retainCompletedHistory_when_invalidatingOldCourseMastery() {
        val dir = folder.newFolder()
        val original = course.copy(source = "built-in", version = "legacy")
        val completed = CoachSession("finished", original, "1.1", status = "complete", stage = "complete",
            turns = listOf(CoachTurn("original", "user", "历史回答", "probe")))
        CoachFileStore(dir).save(CoachState(revision = 4,
            tracks = listOf(CoachTrack(original, demonstrated = setOf("1.1"))), sessions = listOf(completed)))
        val latest = original.copy(version = "new+coach-curriculum-v3", importProtocol = "coach-curriculum-v3", builtInSourceId = "expression")
        val service = CoachCommandService(CoachFileStore(dir), listOf(latest))
        assertTrue(service.state.value.tracks.single().demonstrated.isEmpty())
        assertEquals(completed.copy(requiresCourseReview = true, revision = completed.revision + 1), service.state.value.sessions.single())
        assertFalse(run(service, "dispute", completed.id, "重新评分").success)
    }

    @Test fun should_leaveCustomAndChangedSourcesUntouched_when_loadingNewBundledCriteria() {
        listOf(course.copy(id = "custom", source = "mine"), course.copy(source = "edited course")).forEach { existing ->
            val dir = folder.newFolder()
            val saved = CoachState(revision = 3, tracks = listOf(CoachTrack(existing, demonstrated = setOf("1.1"))))
            CoachFileStore(dir).save(saved)
            val latest = course.copy(source = "bundled source", version = "coach-curriculum-v3+new",
                importProtocol = "coach-curriculum-v3", builtInSourceId = "expression")
            val service = CoachCommandService(CoachFileStore(dir), listOf(latest))
            assertEquals(saved, service.state.value)
        }
    }

    @Test fun should_blockUnreviewedImportedCourse_includingOldSavedSessions() {
        val reviewed = course.copy(source = "unstructured source")
        val needsReview = reviewed.copy(needsCriteriaReview = true,
            units = reviewed.units.map { it.copy(needsCriteriaReview = true) })
        val fresh = CoachCommandService(CoachFileStore(folder.newFolder()), listOf(needsReview))
        val start = run(fresh, "start")
        assertFalse(start.success)
        assertTrue(start.message.contains("草案"))
        val dir = folder.newFolder()
        val oldSession = CoachSession("legacy", reviewed, "1.1", stage = "first")
        CoachFileStore(dir).save(CoachState(tracks = listOf(CoachTrack(reviewed)), sessions = listOf(oldSession)))
        val restored = CoachCommandService(CoachFileStore(dir), listOf(needsReview))
        assertTrue(restored.state.value.tracks.single().course.needsCriteriaReview)
        assertTrue(restored.state.value.sessions.single().requiresCourseReview)
        assertFalse(run(restored, "resume_session", oldSession.id).success)
        assertFalse(run(restored, "start").success)
    }

    @Test fun should_blockLegacyImportedCustomSource_when_noMatchingCurrentCourseExists() {
        val dir = folder.newFolder()
        val legacy = course.copy(id = "custom", version = "1.0+local-012345", source = "旧用户课，尚未重新审阅")
        CoachFileStore(dir).save(CoachState(tracks = listOf(CoachTrack(legacy))))
        val service = CoachCommandService(CoachFileStore(dir), emptyList())
        assertTrue(service.state.value.tracks.single().course.needsCriteriaReview)
        assertEquals(legacy.source, service.state.value.tracks.single().course.source)
        assertFalse(run(service, "start", "custom").success)
    }

    @Test fun should_allowCurrentDispute_when_onlyHistoricalReviewSessionsArePaused() {
        val dir = folder.newFolder()
        val old = CoachSession("old", course.copy(version = "old"), "1.1", status = "paused", requiresCourseReview = true)
        val current = CoachSession("current", course, "1.1", status = "complete", stage = "complete")
        CoachFileStore(dir).save(CoachState(tracks = listOf(CoachTrack(course)), sessions = listOf(old, current)))
        val service = CoachCommandService(CoachFileStore(dir), listOf(course))
        assertTrue(run(service, "dispute", current.id, "请考虑遗漏的事实").success)
        assertEquals(old, service.state.value.sessions.first())
        assertEquals("active", service.state.value.sessions.last().status)
    }

    @Test fun should_notResumeDifferentVersionSession_when_startingCurrentCourse() {
        val dir = folder.newFolder()
        val old = CoachSession("old", course.copy(version = "old"), "1.1", status = "paused")
        CoachFileStore(dir).save(CoachState(tracks = listOf(CoachTrack(course)), sessions = listOf(old)))
        val service = CoachCommandService(CoachFileStore(dir), listOf(course))
        assertFalse(run(service, "resume_session", old.id).success)
        assertTrue(run(service, "start").success)
        assertEquals(2, service.state.value.sessions.size)
        assertEquals(course.version, service.state.value.sessions.last().course.version)
    }
}
