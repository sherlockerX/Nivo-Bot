package io.github.nanomuse.coach

import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.json.JSONObject
import java.util.UUID

/** 用真实领域写入复现延迟保存、旧编辑器销毁和题目切换之间的冲突。 */
class CoachAnswerDraftPolicyTest {
    @get:Rule val folder = TemporaryFolder()
    private val course = CoachCourse("expression", "表达", "讨论室", CoachKind.EXPRESSION,
        listOf(CoachUnit("1", "回应关切", "回应对方担忧", "情景对话",
            listOf(CoachCriterion("concern", "回应关切")))), "v1")

    private fun service(): CoachCommandService {
        val service = CoachCommandService(CoachFileStore(folder.newFolder()), listOf(course))
        command(service, "start", course.id)
        command(service, "coach_reply", text = "对方说：你怎么又拖到现在？", next = "first")
        return service
    }

    private fun session(service: CoachCommandService) = service.state.value.sessions.single()

    private fun command(service: CoachCommandService, action: String,
        id: String = session(service).id, text: String = "", next: String? = null) {
        val payload = next?.let { JSONObject().put("next", it)
            .put("requestTurnId", session(service).pendingTurnId.orEmpty()).toString() }.orEmpty()
        val user = if (action == "answer") CoachUserInput(UUID.randomUUID().toString(), text) else null
        val result = service.execute(CoachCommand(action, UUID.randomUUID().toString(),
            service.state.value.revision, id, text, payload), user)
        assertTrue(result.message, result.success)
    }

    @Test fun should_reject_dispose_flush_immediately_after_answer_clears_draft() {
        val service = service()
        val editor = CoachAnswerDraftPolicy.target(session(service))
        val text = "我理解你担心进度，我下午同步已完成的部分。"
        CoachAnswerDraftPolicy.save(service, editor, text)
        command(service, "answer", text = text)
        val committed = service.state.value
        CoachAnswerDraftPolicy.save(service, editor, text)
        assertEquals("", session(service).draft)
        assertEquals(committed, service.state.value)
        assertEquals(text, session(service).turns.single { it.role == "user" }.text)
    }

    @Test fun should_reject_old_350ms_save_after_probe_and_after_complete() {
        val service = service()
        val editor = CoachAnswerDraftPolicy.target(session(service))
        val first = "我理解你的担心，今天三点同步进度。"
        command(service, "answer", text = first)
        command(service, "coach_reply", text = "朋友说：你又临时改计划。你怎么回应？", next = "probe")
        val probe = service.state.value
        CoachAnswerDraftPolicy.save(service, editor, first)
        assertEquals(probe, service.state.value)
        assertEquals("", session(service).draft)
        command(service, "answer", text = "临时改动让你很难安排时间，我会提前和你确认。")
        command(service, "coach_reply", text = "本轮已完成，保留两次原话。", next = "complete")
        val complete = service.state.value
        CoachAnswerDraftPolicy.save(service, editor, first)
        assertEquals(complete, service.state.value)
        assertEquals("", session(service).draft)
        assertEquals(2, session(service).turns.count { it.role == "user" })
    }

    @Test fun should_reject_old_retry_editor_even_if_stage_name_is_unchanged() {
        val service = service()
        command(service, "answer", text = "我刚才在忙别的。")
        command(service, "coach_reply", text = "先回应进度担心，再试一次。", next = "retry")
        val oldRetryEditor = CoachAnswerDraftPolicy.target(session(service))
        command(service, "answer", text = "我会明天处理。")
        command(service, "coach_reply", text = "还没有回应对方担心，再试一次。", next = "retry")
        val latest = service.state.value
        CoachAnswerDraftPolicy.save(service, oldRetryEditor, "上一次重试的旧草稿")
        assertEquals(latest, service.state.value)
        assertEquals("", session(service).draft)
    }

    @Test fun should_keep_valid_draft_edits_across_autosaves_without_replacing_editor() {
        val service = service()
        val editor = CoachAnswerDraftPolicy.target(session(service))
        assertTrue(CoachAnswerDraftPolicy.save(service, editor, "先写半句")!!.success)
        assertEquals(editor, CoachAnswerDraftPolicy.target(session(service)))
        assertTrue(CoachAnswerDraftPolicy.save(service, editor, "先回应你对进度的担心")!!.success)
        val saved = service.state.value
        assertNull(CoachAnswerDraftPolicy.save(service, editor, "先回应你对进度的担心"))
        assertEquals(saved, service.state.value)
        assertTrue(CoachAnswerDraftPolicy.save(service, editor, "")!!.success)
        assertEquals("", session(service).draft)
        assertEquals(editor, CoachAnswerDraftPolicy.target(session(service)))
    }

    @Test fun should_reject_flush_from_editor_before_pause() {
        val service = service()
        val editor = CoachAnswerDraftPolicy.target(session(service))
        command(service, "pause_session", text = "暂停时保存的真实草稿")
        val paused = service.state.value
        CoachAnswerDraftPolicy.save(service, editor, "旧编辑器里的内容")
        assertEquals(paused, service.state.value)
    }

    @Test fun should_drop_cancelled_debounce_after_a_newer_local_value_was_saved() {
        val service = service()
        val editor = CoachAnswerDraftPolicy.target(session(service))
        var currentText = "刚开始写的半句"
        val delayedText = currentText
        currentText = "后来写完整的真实草稿"
        CoachAnswerDraftPolicy.save(service, editor, currentText)
        val saved = service.state.value
        assertNull(CoachAnswerDraftPolicy.save(service, editor, delayedText) { currentText == delayedText })
        assertEquals(saved, service.state.value)
        assertNull(CoachAnswerDraftPolicy.save(service, editor, "销毁后迟到的保存") { false })
        assertEquals(saved, service.state.value)
    }

    @Test fun should_check_editor_and_commit_under_the_domain_service_monitor() {
        val service = service()
        val editor = CoachAnswerDraftPolicy.target(session(service))
        var checkedInsideTransaction = false
        val result = CoachAnswerDraftPolicy.save(service, editor, "有效草稿") {
            checkedInsideTransaction = Thread.holdsLock(service)
            true
        }
        assertTrue(checkedInsideTransaction)
        assertTrue(result!!.success)
        assertEquals("有效草稿", session(service).draft)
    }
}
