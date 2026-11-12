package io.github.nanomuse.coach

import java.io.File
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/** 用完整回合验证提示、现实证据、改课与失败恢复的边界。 */
class CoachEvidenceTest {
    @get:Rule val temporary = TemporaryFolder()
    private fun course(real: Boolean = false) = CoachCourse("test", "练习", "书房", CoachKind.JUDGMENT,
        listOf(CoachUnit("1.1", "依据", "说出依据", "比较", listOf(CoachCriterion("evidence", "有依据", real)), "自拟练习"),
            CoachUnit("1.2", "修正", "修正判断", "比较", listOf(CoachCriterion("update", "说明修正")), "自拟练习")),
        "v1", "自拟练习，不声称外部理论已核实")
    private fun service(real: Boolean = false) = CoachCommandService(CoachFileStore(temporary.newFolder()), listOf(course(real)))
    private fun call(service: CoachCommandService, action: String, id: String = "test", text: String = "", payload: String = "",
        user: CoachUserInput? = null): CoachResult = service.execute(CoachCommand(action, java.util.UUID.randomUUID().toString(),
            service.state.value.revision, id, text, if (action == "coach_reply" && payload.isNotBlank()) JSONObject(payload).put("requestTurnId", service.state.value.sessions.find { it.id == id }?.pendingTurnId ?: "").toString() else payload), user)
    private fun answer(service: CoachCommandService, id: String, text: String) = call(service, "answer", id, text,
        user = CoachUserInput(java.util.UUID.randomUUID().toString(), text))
    private fun scene(service: CoachCommandService): String {
        val id = call(service, "start").targetId
        assertTrue(call(service, "coach_reply", id, "同事说项目一定会延期。你依据什么判断？", "{\"next\":\"first\"}").success)
        assertTrue(answer(service, id, "我还不知道剩余工作量").success)
        return id
    }
    private fun evidencePayload(turn: CoachTurn, next: String = "complete") = JSONObject().put("next", next)
        .put("evidence", org.json.JSONArray().put(JSONObject().put("criterionId", "evidence")
            .put("turnId", turn.id).put("quote", turn.text).put("reason", "说明了事实和待核对条件").put("met", true))).toString()

    @Test fun should_require_novel_independent_attempt_before_advancing() {
        val service = service()
        val id = scene(service)
        val first = service.state.value.sessions.single().turns.last()
        assertFalse(call(service, "coach_reply", id, "已掌握", evidencePayload(first)).success)
        assertTrue(call(service, "coach_reply", id, "换成购买课程：评价都很好，你如何判断是否适合？", "{\"next\":\"probe\"}").success)
        assertTrue(answer(service, id, "评价是他人体验，我需要核对课程目标与我的需求").success)
        val independent = service.state.value.sessions.single().turns.last()
        assertTrue(call(service, "coach_reply", id, "你区分了外部评价和自己的证据需求。", evidencePayload(independent)).success)
        assertEquals(setOf("1.1"), service.state.value.tracks.single().demonstrated)
        assertEquals("1.1", service.state.value.tracks.single().currentUnitId)
        assertTrue(call(service, "advance").success)
        assertEquals("1.2", service.state.value.tracks.single().currentUnitId)
    }

    @Test fun should_keep_hint_request_out_of_independent_evidence() {
        val service = service()
        val id = scene(service)
        call(service, "coach_reply", id, "新场景如何判断？", "{\"next\":\"probe\"}")
        assertTrue(call(service, "request_hint", id).success)
        call(service, "coach_reply", id, "先列出未知条件。", "{\"next\":\"retry\"}")
        answer(service, id, "我需要更多资料")
        val supported = service.state.value.sessions.single().turns.last()
        assertEquals("hinted", supported.support)
        assertFalse(call(service, "coach_reply", id, "独立通过", evidencePayload(supported)).success)
        assertTrue(service.state.value.tracks.single().demonstrated.isEmpty())
        assertEquals(2, service.state.value.sessions.single().turns.count { it.role == "user" })
    }

    @Test fun should_require_real_report_for_real_action_criterion() {
        val service = service(real = true)
        val id = scene(service)
        call(service, "coach_reply", id, "新场景", "{\"next\":\"probe\"}")
        answer(service, id, "我打算去做")
        val planned = service.state.value.sessions.single().turns.last()
        assertFalse(call(service, "coach_reply", id, "行动完成", evidencePayload(planned)).success)
        assertTrue(call(service, "coach_reply", id, "准备已保存，等待真实行动。", "{\"next\":\"complete\"}").success)
        assertEquals("waiting_real", service.state.value.sessions.single().status)
        val task = call(service, "action_plan", id, "今天向同事核对一项条件").targetId
        assertTrue(call(service, "action_report", task, "今天实际问了同事，发现还缺两项数据",
            user = CoachUserInput("real1", "今天实际问了同事，发现还缺两项数据")).success)
        val real = service.state.value.sessions.single().turns.last()
        assertEquals("reported_real", real.context)
        assertTrue(call(service, "coach_reply", id, "实际行动有了具体反馈。", evidencePayload(real)).success)
        assertEquals(setOf("1.1"), service.state.value.tracks.single().demonstrated)
    }

    @Test fun should_invalidate_proposal_when_goal_changes() {
        val service = service()
        val id = call(service, "new_draft", text = "想练判断").targetId
        val proposal = JSONObject().put("course", JSONObject(Json.encodeToString(course())))
            .put("sourceStatus", "self_authored").toString()
        assertTrue(call(service, "propose", id, payload = proposal, user = CoachUserInput("u1", "请建议课程")).success)
        val revision = service.state.value.drafts.single().revision
        assertFalse(call(service, "activate", id, payload = "{\"draftRevision\":$revision}", user = CoachUserInput("u1", "创建")).success)
        call(service, "revise_draft", id, "想练边界表达")
        assertFalse(call(service, "activate", id, payload = "{\"draftRevision\":$revision}", user = CoachUserInput("u2", "确认创建")).success)
        assertEquals(1, service.state.value.tracks.size)
        assertNull(service.state.value.drafts.single().course)
    }

    @Test fun should_keepPriorSessionsReadOnly_when_activatingSameCourseIdWithNewCriteria() {
        val service = service()
        val oldId = scene(service)
        val old = service.state.value.sessions.single()
        val draftId = call(service, "new_draft", text = "改进判断课").targetId
        val proposal = JSONObject().put("course", JSONObject(Json.encodeToString(course())))
            .put("sourceStatus", "self_authored").toString()
        assertTrue(call(service, "propose", draftId, payload = proposal, user = CoachUserInput("proposal", "请修订课程")).success)
        val revision = service.state.value.drafts.single().revision
        assertTrue(call(service, "activate", draftId, payload = "{\"draftRevision\":$revision}",
            user = CoachUserInput("confirm", "确认创建")).success)
        val preserved = service.state.value.sessions.single()
        assertEquals(old.course, preserved.course)
        assertEquals(old.turns, preserved.turns)
        assertEquals(old.pendingTurnId, preserved.pendingTurnId)
        assertTrue(preserved.requiresCourseReview)
        assertEquals("paused", preserved.status)
        assertFalse(call(service, "resume_session", oldId).success)
        val freshId = call(service, "start").targetId
        assertNotEquals(oldId, freshId)
        assertEquals(service.state.value.tracks.single().course.version, service.state.value.sessions.last().course.version)
    }

    @Test fun should_rejectUnreviewedFlags_when_proposingStructuredCourse() {
        val service = service()
        val draft = call(service, "new_draft", text = "审阅课程").targetId
        listOf(course().copy(needsCriteriaReview = true), course().copy(units = course().units.map {
            it.copy(needsCriteriaReview = true)
        })).forEach { unreviewed ->
            val proposal = JSONObject().put("course", JSONObject(Json.encodeToString(unreviewed)))
                .put("sourceStatus", "self_authored").toString()
            assertFalse(call(service, "propose", draft, payload = proposal).success)
        }
        assertNull(service.state.value.drafts.single().course)
    }

    @Test fun should_restore_backup_without_destroying_it_when_primary_is_corrupt() {
        val dir = temporary.newFolder()
        val service = CoachCommandService(CoachFileStore(dir), listOf(course()))
        call(service, "pause_course")
        call(service, "resume_course")
        File(dir, "state.json").writeText("bad snapshot")
        val restored = CoachCommandService(CoachFileStore(dir), listOf(course()))
        assertTrue(restored.state.value.tracks.single().paused)
        assertTrue(call(restored, "resume_course").success)
        assertTrue(File(dir, "state.backup.json").readText().contains("\"paused\":true"))
    }

    @Test fun should_not_publish_success_when_snapshot_write_fails() {
        val dir = temporary.newFolder()
        val service = CoachCommandService(CoachFileStore(dir), listOf(course()))
        File(dir, "state.pending.json").mkdir()
        assertFalse(call(service, "pause_course").success)
        assertFalse(service.state.value.tracks.single().paused)
        assertEquals(0, service.state.value.revision)
    }

    @Test fun should_reject_reused_operation_with_different_meaning() {
        val service = service()
        assertTrue(service.execute(CoachCommand("pause_course", "unique", 0, "test")).success)
        assertFalse(service.execute(CoachCommand("resume_course", "unique", 1, "test")).success)
        assertTrue(service.state.value.tracks.single().paused)
    }
}
