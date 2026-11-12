package io.github.nanomuse.coach

import java.util.UUID
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/** 专题教学允许连续讲解和跨课续学，但结束课次不能伪造达成证据。 */
class CoachTopicProtocolTest {
    @get:Rule val folder = TemporaryFolder()
    private val course = CoachCourse("expression", "表达", "会客厅", CoachKind.EXPRESSION,
        listOf(CoachUnit("1.1", "理解关切", "解释并回应关切", "案例教学",
            listOf(CoachCriterion("understanding", "解释机制"),
                CoachCriterion("application", "独立回应")), "自拟练习")), "v1", "自拟练习")

    private fun service() = CoachCommandService(CoachFileStore(folder.newFolder()), listOf(course))

    private fun command(service: CoachCommandService, action: String, target: String = "expression",
        text: String = "", payload: String = "", user: CoachUserInput? = null) = service.execute(
        CoachCommand(action, UUID.randomUUID().toString(), service.state.value.revision,
            target, text, payload), user)

    @Test fun should_startTopicAndSeveralLessons_withoutMarkingMastery() {
        val service = service()
        val topic = command(service, "start_topic", text = "组会被打断时怎样回应")
        assertTrue(topic.message, topic.success)
        val first = command(service, "start_lesson", topic.targetId)
        assertTrue(first.message, first.success)
        assertTrue(command(service, "coach_reply", first.targetId, "先分析被打断时的目标与约束。",
            """{"mode":"explain"}""").success)
        assertTrue(command(service, "end_lesson", first.targetId, "下次继续比较不同回应方法。").success)
        assertTrue(service.state.value.tracks.single().demonstrated.isEmpty())
        val second = command(service, "start_lesson", topic.targetId)
        assertTrue(second.success)
        assertNotEquals(first.targetId, second.targetId)
        assertEquals(2, service.state.value.sessions.size)
    }

    @Test fun should_saveQuestionsAndContinuousExplanation_withoutFakeAttempt() {
        val service = service()
        val topic = command(service, "start_topic", text = "比较沟通中的不同解释")
        assertTrue(topic.message, topic.success)
        val lesson = command(service, "start_lesson", topic.targetId).targetId
        assertTrue(command(service, "coach_reply", lesson, "先说明事实与解释的区别。", """{"mode":"explain"}""").success)
        val question = "为什么同一个事件会有不同解释？"
        assertTrue(command(service, "lesson_message", lesson, question, """{"purpose":"question"}""",
            CoachUserInput("question-1", question, "chat-1")).success)
        val pending = service.state.value.sessions.single().pendingTurnId
        assertTrue(command(service, "coach_reply", lesson, "不同理论关注的变量不同，先比较可观察的预测。",
            JSONObject().put("mode", "compare").put("requestTurnId", pending).toString()).success)
        assertTrue(command(service, "coach_reply", lesson, "再看一个反例和它对解释范围的限制。", """{"mode":"concept"}""").success)
        assertEquals(4, service.state.value.sessions.single().turns.size)
        assertTrue(service.state.value.sessions.single().evidence.isEmpty())
    }

    @Test fun should_keepHostBindingAndArchiveOrdinaryDiscussion_oncePerMessage() {
        val service = service()
        val topic = command(service, "start_topic", text = "共同分析案例").targetId
        assertTrue(service.bindTopicConversation(topic, "chat-topic").success)
        assertFalse(service.bindTopicConversation(topic, "other-chat").success)
        val user = service.registerConversationUser("chat-topic", "user-1", "先从概念讲起")
        assertTrue(user.message, user.success)
        assertTrue(service.registerConversationUser("chat-topic", "user-1", "先从概念讲起").success)
        assertTrue(service.recordConversationReply("chat-topic", "assistant-1", "从概念和机制开始。").success)
        assertTrue(service.recordConversationReply("chat-topic", "assistant-1", "从概念和机制开始。").success)
        assertEquals(2, service.state.value.sessions.single().turns.size)
        assertFalse(command(service, "answer", user.targetId, "先从概念讲起",
            user = CoachUserInput("user-1", "先从概念讲起", "chat-topic")).success)
        assertTrue(service.state.value.sessions.single().evidence.isEmpty())
    }

    @Test fun should_keepEndedLessonForOrdinaryFollowup_untilExplicitlyStartingAnotherLesson() {
        val service = service()
        val topic = command(service, "start_topic", text = "长期案例").targetId
        service.bindTopicConversation(topic, "chat-topic")
        val first = service.registerConversationUser("chat-topic", "user-1", "今天先结束这一节").targetId
        val ended = command(service, "end_lesson", first, "已保存本节问题，下次继续。")
        assertTrue(ended.message, ended.success)
        assertTrue(service.recordConversationReply("chat-topic", "assistant-1", "下次继续。").success)
        val followup = service.registerConversationUser("chat-topic", "user-2", "补充一个更正").targetId
        assertEquals(first, followup)
        assertEquals(1, service.state.value.sessions.size)
        assertTrue(service.recordConversationReply("chat-topic", "assistant-2", "更正已保留在这一课。").success)
        val second = command(service, "start_lesson", topic).targetId
        assertNotEquals(first, second)
        assertEquals("chat-topic", service.topicForConversation("chat-topic")!!.chatSessionId)
        assertEquals(listOf("complete", "active"), service.state.value.sessions.map { it.status })
    }

    @Test fun should_rejectCrossTopicMutation_evenWhenReplayingExistingOperation() {
        val service = service()
        val topic = command(service, "start_topic", text = "案例甲").targetId
        service.bindTopicConversation(topic, "chat-a")
        val otherTopic = command(service, "start_topic", text = "案例乙").targetId
        service.bindTopicConversation(otherTopic, "chat-b")
        val otherLesson = command(service, "start_lesson", otherTopic).targetId
        val saved = CoachCommand("save_input", "saved-other", service.state.value.revision, otherLesson, "乙的草稿")
        assertTrue(service.execute(saved).success)
        assertFalse(service.execute(saved, scope = CoachConversationScope("chat-a")).success)
        val visible = CoachScopePolicy.visibleState(service.state.value, CoachConversationScope("chat-a"))
        assertEquals(listOf(topic), visible.topics.map { it.id })
        assertTrue(visible.sessions.isEmpty())
        assertEquals("乙的草稿", service.state.value.sessions.single().draft)
    }

    @Test fun should_requireBothDimensionsAndHostElapsedTime_forIndependentAndDelayedEvidence() {
        var now = 1_000L
        val service = CoachCommandService(CoachFileStore(folder.newFolder()), listOf(course), clock = { now })
        val topic = command(service, "start_topic", text = "长期比较").targetId
        val first = command(service, "start_lesson", topic).targetId
        saveEvidence(service, first, "understanding", "解释为什么需要区分事实和推断", "事实能核对，推断依赖假设")
        assertTrue(CoachTeachingProtocol.progress(service.state.value, topic).hasUnderstanding)
        assertFalse(CoachTeachingProtocol.progress(service.state.value, topic).isDemonstrated)
        saveEvidence(service, first, "application", "同事说进展太慢，你怎样回应", "先问哪一步影响了他的目标，再核对进度")
        val progress = CoachTeachingProtocol.progress(service.state.value, topic)
        assertTrue(progress.hasApplication)
        assertFalse(progress.isDemonstrated)
        assertFalse(progress.hasDelayedReview)
        assertTrue(command(service, "end_lesson", first).success)
        val second = command(service, "start_lesson", topic).targetId
        val delayed = JSONObject().put("mode", "review").put("assessment", JSONObject()
            .put("dimension", "understanding").put("reviewOfSessionId", first).put("isDelayed", true)).toString()
        assertFalse(command(service, "coach_reply", second, "请重新说明边界", delayed).success)
        now += CoachTeachingProtocol.MIN_DELAY_MILLIS
        assertTrue(command(service, "coach_reply", second, "请重新说明边界", delayed).success)
        assertTrue(service.state.value.sessions.last().assessment!!.isDelayed)
        val text = "事实与推断之间必须说明假设"
        assertTrue(command(service, "answer", second, text, user = CoachUserInput("review-user", text)).success)
        val turn = service.state.value.sessions.last().turns.last()
        assertTrue(command(service, "coach_reply", second, "你说明了推断的条件。", evidence(turn, "understanding")).success)
        assertTrue(CoachTeachingProtocol.progress(service.state.value, topic).hasDelayedReview)
        assertTrue(CoachTeachingProtocol.progress(service.state.value, topic).isDemonstrated)
        service.bindTopicConversation(topic, "review-chat")
        val original = service.state.value.sessions.first().turns.first { it.role == "user" }
        assertTrue(service.invalidateMessage("review-chat", original.originMessageId, "复核基线原文被删除").success)
        assertFalse(CoachTeachingProtocol.progress(service.state.value, topic).hasDelayedReview)
        assertFalse(CoachTeachingProtocol.progress(service.state.value, topic).isDemonstrated)
    }

    @Test fun should_keepHintedAttemptOutOfIndependentEvidence() {
        val service = service()
        val topic = command(service, "start_topic", text = "提示边界").targetId
        val lesson = command(service, "start_lesson", topic).targetId
        command(service, "coach_reply", lesson, "解释机制", """{"mode":"practice","assessment":{"dimension":"understanding"}}""")
        assertTrue(command(service, "request_hint", lesson).success)
        val text = "根据提示解释机制"
        assertTrue(command(service, "answer", lesson, text, user = CoachUserInput("hinted", text)).success)
        val turn = service.state.value.sessions.last().turns.last()
        assertEquals("hinted", turn.support)
        assertFalse(command(service, "coach_reply", lesson, "通过", evidence(turn, "understanding")).success)
        assertFalse(CoachTeachingProtocol.progress(service.state.value, topic).hasUnderstanding)
    }

    @Test fun should_readVersionTwoWithoutInventingTopicsOrDualEvidence() {
        val directory = folder.newFolder()
        val legacy = CoachSession("old", course, "1.1", status = "complete", stage = "complete",
            turns = listOf(CoachTurn("old-user", "user", "旧记录", "probe")))
        val state = CoachState(schemaVersion = 2, tracks = listOf(CoachTrack(course, demonstrated = setOf("1.1"))),
            sessions = listOf(legacy))
        CoachFileStore(directory).save(state)
        val service = CoachCommandService(CoachFileStore(directory), listOf(course))
        assertEquals(state, service.state.value)
        assertEquals("legacy", service.state.value.sessions.single().teachingProtocol)
        assertTrue(service.state.value.topics.isEmpty())
        val topic = command(service, "start_topic", text = "新案例").targetId
        assertFalse(CoachTeachingProtocol.progress(service.state.value, topic).hasUnderstanding)
        assertEquals(3, CoachFileStore(directory).load()!!.schemaVersion)
        assertEquals(legacy, service.state.value.sessions.single())
    }

    @Test fun should_keepRealReportSeparateFromSimulationInTopicLesson() {
        val realCourse = course.copy(units = course.units.map { unit -> unit.copy(criteria = unit.criteria +
            CoachCriterion("practice", "报告真实沟通", requiresRealAction = true, dimension = "application")) })
        val service = CoachCommandService(CoachFileStore(folder.newFolder()), listOf(realCourse))
        val topic = command(service, "start_topic", text = "现实回应").targetId
        val lesson = command(service, "start_lesson", topic).targetId
        saveEvidence(service, lesson, "understanding", "为什么先问关切", "先确定对方目标才能选择相关回应")
        saveEvidence(service, lesson, "application", "对方在模拟场景里发问", "我会先问你担心什么")
        assertFalse(CoachTeachingProtocol.progress(service.state.value, topic).hasApplication)
        val action = command(service, "action_plan", lesson, "实际询问一次同事").targetId
        val report = "今天实际问了同事，发现他关心的是截止时间"
        assertTrue(command(service, "action_report", action, report,
            user = CoachUserInput("real-user", report)).success)
        val turn = service.state.value.sessions.single().turns.last()
        assertTrue(command(service, "coach_reply", lesson, "这项实际反馈已记录。", evidence(turn, "practice")).success)
        assertTrue(CoachTeachingProtocol.progress(service.state.value, topic).hasApplication)
    }

    @Test fun should_keepAssessmentSupportIndependent_whenHintCameBeforeFreshQuestion() {
        val service = service()
        val topic = command(service, "start_topic", text = "提示后再测").targetId
        val lesson = command(service, "start_lesson", topic).targetId
        assertTrue(command(service, "request_hint", lesson).success)
        saveEvidence(service, lesson, "understanding", "请用一个不同例子解释事实与推断的区别", "事实可核对而推断还依赖未证实假设")
        assertTrue(CoachTeachingProtocol.progress(service.state.value, topic).hasUnderstanding)
    }

    @Test fun should_reuseHostSavedUser_when_classifyingActualActionReport() {
        val service = service()
        val topic = command(service, "start_topic", text = "已归档报告").targetId
        service.bindTopicConversation(topic, "chat-report")
        val lesson = command(service, "start_lesson", topic).targetId
        val action = command(service, "action_plan", lesson, "实际询问一次").targetId
        val text = "今天实际询问了同事，他希望提前看到数据"
        assertTrue(service.registerConversationUser("chat-report", "report-user", text).success)
        val result = command(service, "action_report", action, text,
            user = CoachUserInput("report-user", text, "chat-report"))
        assertTrue(result.message, result.success)
        val users = service.state.value.sessions.single().turns.filter { it.role == "user" }
        assertEquals(1, users.size)
        assertEquals("reported_real", users.single().context)
        assertEquals(users.single(), service.state.value.actions.single().reports.single())
    }

    @Test fun should_revokeMasteryAndPreserveOriginalText_when_sourceMessageChanges() {
        val service = service()
        val topic = command(service, "start_topic", text = "可追溯来源").targetId
        service.bindTopicConversation(topic, "chat-source")
        val lesson = command(service, "start_lesson", topic).targetId
        saveEvidence(service, lesson, "understanding", "说明机制", "我的解释需要可核对事实")
        saveEvidence(service, lesson, "application", "新情境怎样回应", "我先询问对方目标再提出行动")
        val original = service.state.value.sessions.single().turns.first { it.role == "user" }
        assertTrue(CoachTeachingProtocol.progress(service.state.value, topic).hasUnderstanding)
        assertTrue(service.invalidateMessage("chat-source", original.originMessageId, "原消息被编辑").success)
        val preserved = service.state.value.sessions.single().turns.single { it.id == original.id }
        assertEquals(original.text, preserved.text)
        assertTrue(preserved.sourceInvalidated)
        assertFalse(CoachTeachingProtocol.progress(service.state.value, topic).hasUnderstanding)
        assertTrue(service.state.value.tracks.single().demonstrated.isEmpty())
    }

    @Test fun should_archiveDeletedConversation_withoutRebindingOrReusingItsEvidence() {
        val service = service()
        val topic = command(service, "start_topic", text = "删除后的档案").targetId
        service.bindTopicConversation(topic, "deleted-chat")
        val lesson = command(service, "start_lesson", topic).targetId
        saveEvidence(service, lesson, "understanding", "说明机制", "我能解释可核对性")
        assertTrue(service.invalidateConversation("deleted-chat", "聊天已删除").success)
        assertFalse(service.bindTopicConversation(topic, "replacement-chat").success)
        assertFalse(service.registerConversationUser("deleted-chat", "new-user", "继续").success)
        assertFalse(command(service, "coach_reply", lesson, "不能修改历史", """{"mode":"explain"}""").success)
        assertFalse(command(service, "save_input", lesson, "不能修改历史").success)
        assertEquals("archived", service.state.value.topics.single().status)
        val fresh = command(service, "start_topic", text = "删除后的档案").targetId
        assertNotEquals(topic, fresh)
        assertFalse(CoachTeachingProtocol.progress(service.state.value, fresh).hasUnderstanding)
    }

    @Test fun should_rejectSavedMessageWithChangedText_insteadOfSilentlyReusingSource() {
        val service = service()
        val topic = command(service, "start_topic", text = "原文一致性").targetId
        service.bindTopicConversation(topic, "chat-source")
        assertTrue(service.registerConversationUser("chat-source", "same-id", "原始问题").success)
        assertFalse(service.registerConversationUser("chat-source", "same-id", "修改后的问题").success)
        assertTrue(service.recordConversationReply("chat-source", "reply-id", "原始回复").success)
        assertFalse(service.recordConversationReply("chat-source", "reply-id", "修改后的回复").success)
    }

    @Test fun should_rejectInventedDimensionAndSingleDimension_when_proposalDeclaresNewEvidence() {
        val service = service()
        val draft = command(service, "new_draft", text = "创建双证据课程").targetId
        val invalid = listOf("mind_reading", "understanding").map { dimension ->
            course.copy(units = course.units.map { it.copy(criteria = listOf(CoachCriterion("target", "解释机制", dimension = dimension))) })
        }
        invalid.forEach { proposal ->
            val payload = JSONObject().put("sourceStatus", "self_authored").put("course",
                JSONObject(kotlinx.serialization.json.Json.encodeToString(CoachCourse.serializer(), proposal))).toString()
            assertFalse(command(service, "propose", draft, payload = payload).success)
        }
    }

    @Test fun should_continueAfterFailedTeaching_withoutLosingEarlierUserMessage() {
        val service = service()
        val topic = command(service, "start_topic", text = "失败后的追问").targetId
        service.bindTopicConversation(topic, "chat-retry")
        val first = service.registerConversationUser("chat-retry", "first-question", "先说明概念")
        assertTrue(first.success)
        val second = service.registerConversationUser("chat-retry", "second-question", "刚才没有回复，请接着说明", first.targetId)
        assertTrue(second.message, second.success)
        val session = service.state.value.sessions.single()
        assertEquals(2, session.turns.size)
        assertEquals(session.turns.last().id, session.pendingTurnId)
        assertTrue(service.recordConversationReply("chat-retry", "reply", "现在继续解释。", first.targetId).success)
        assertNull(service.state.value.sessions.single().pendingTurnId)
    }

    @Test fun should_preserveUnassessedAttempt_when_followupAndOrdinaryReplyArrive() {
        val service = service()
        val topic = command(service, "start_topic", text = "待评估作答").targetId
        service.bindTopicConversation(topic, "chat-attempt")
        val lesson = command(service, "start_lesson", topic).targetId
        command(service, "coach_reply", lesson, "请独立解释机制", """{"mode":"practice","assessment":{"dimension":"understanding"}}""")
        assertTrue(service.recordConversationReply("chat-attempt", "question", "请独立解释机制", lesson).success)
        val text = "我认为需要区分事实和推断"
        command(service, "answer", lesson, text, user = CoachUserInput("attempt", text, "chat-attempt"))
        val attemptId = service.state.value.sessions.single().pendingTurnId
        assertTrue(service.registerConversationUser("chat-attempt", "followup", "上次作答还没评，请继续", lesson).success)
        assertTrue(service.recordConversationReply("chat-attempt", "reply", "我先补充一个概念。", lesson).success)
        assertEquals(attemptId, service.state.value.sessions.single().pendingTurnId)
        assertFalse(command(service, "end_lesson", lesson).success)
        val payload = JSONObject().put("requestTurnId", attemptId).put("mode", "explain").toString()
        assertTrue(command(service, "coach_reply", lesson, "这次回答还缺少假设条件，暂不记录通过证据。", payload).success)
        assertNull(service.state.value.sessions.single().pendingTurnId)
    }

    @Test fun should_rejectLateHostReply_when_nextLessonHasStarted() {
        val service = service()
        val topic = command(service, "start_topic", text = "迟到回复").targetId
        service.bindTopicConversation(topic, "chat-late")
        val first = command(service, "start_lesson", topic).targetId
        command(service, "end_lesson", first)
        val second = command(service, "start_lesson", topic).targetId
        assertFalse(service.recordConversationReply("chat-late", "late-reply", "属于第一节的回复", first).success)
        assertFalse(service.registerConversationUser("chat-late", "late-user", "第一节延迟原话", first).success)
        assertTrue(service.state.value.sessions.single { it.id == second }.turns.isEmpty())
    }

    @Test fun should_storeVerifiableSummarySourcesAndRejectInventedQuotes() {
        val service = service()
        val topic = command(service, "start_topic", text = "摘要来源").targetId
        service.bindTopicConversation(topic, "chat-summary")
        val lesson = service.registerConversationUser("chat-summary", "source-user", "我更正刚才的描述，原因仍不确定").targetId
        val turn = service.state.value.sessions.single().turns.single()
        val invalid = JSONObject().put("corrections", org.json.JSONArray().put(JSONObject()
            .put("turnId", turn.id).put("quote", "伪造更正"))).toString()
        assertFalse(command(service, "end_lesson", lesson, "总结", invalid).success)
        val valid = JSONObject().put("corrections", org.json.JSONArray().put(JSONObject()
            .put("turnId", turn.id).put("quote", "我更正刚才的描述")))
            .put("unresolvedHypotheses", org.json.JSONArray().put(JSONObject()
                .put("turnId", turn.id).put("quote", "原因仍不确定"))).toString()
        assertTrue(command(service, "end_lesson", lesson, "保留更正和待核对原因。", valid).success)
        val summary = service.state.value.sessions.single().lessonSummary!!
        assertEquals(course.version, summary.courseVersion)
        assertEquals("source-user", summary.corrections.single().messageId)
        assertEquals("原因仍不确定", summary.unresolvedHypotheses.single().quote)
        service.invalidateMessage("chat-summary", "source-user", "用户删除原话")
        assertTrue(service.state.value.sessions.single().lessonSummary!!.sourceInvalidated)
    }

    @Test fun should_deleteOnlyChosenTopicArchive_when_hostPurgesConversation() {
        val directory = folder.newFolder()
        val service = CoachCommandService(CoachFileStore(directory), listOf(course))
        val topic = command(service, "start_topic", text = "删除目标").targetId
        service.bindTopicConversation(topic, "chat-delete")
        val lesson = service.registerConversationUser("chat-delete", "private", "需要删除的原话").targetId
        command(service, "action_plan", lesson, "需要删除的计划")
        val other = command(service, "start_topic", text = "保留案例").targetId
        val result = service.purgeConversation("chat-delete")
        assertTrue(result.message, result.success)
        assertEquals(listOf(other), service.state.value.topics.map { it.id })
        assertTrue(service.state.value.sessions.isEmpty())
        assertTrue(service.state.value.actions.isEmpty())
        assertNull(service.topicForConversation("chat-delete"))
        assertFalse(java.io.File(directory, "state.backup.json").readText().contains("需要删除的原话"))
        val reloaded = CoachCommandService(CoachFileStore(directory), listOf(course))
        assertEquals(service.state.value, reloaded.state.value)
    }

    @Test fun should_invalidateToolAssessment_when_finalAssistantMessageIsDeleted() {
        val service = service()
        val topic = command(service, "start_topic", text = "题目来源").targetId
        service.bindTopicConversation(topic, "chat-question")
        val lesson = service.registerConversationUser("chat-question", "request", "请出一道独立验证题").targetId
        val pending = service.state.value.sessions.single().pendingTurnId
        val payload = JSONObject().put("mode", "practice").put("requestTurnId", pending)
            .put("assessment", JSONObject().put("dimension", "understanding")).toString()
        assertTrue(command(service, "coach_reply", lesson, "用自己的话解释事实与推断", payload).success)
        assertTrue(service.recordConversationReply("chat-question", "question-message",
            "用自己的话解释事实与推断。请说明二者区别，举一个自己的例子。", lesson).success)
        val text = "事实可以核对，推断需要假设"
        assertTrue(command(service, "answer", lesson, text, user = CoachUserInput("attempt", text, "chat-question")).success)
        val turn = service.state.value.sessions.single().turns.last()
        assertTrue(command(service, "coach_reply", lesson, "证据已记录", evidence(turn, "understanding")).success)
        assertTrue(CoachTeachingProtocol.progress(service.state.value, topic).hasUnderstanding)
        service.invalidateMessage("chat-question", "question-message", "题目消息被删除")
        assertFalse(CoachTeachingProtocol.progress(service.state.value, topic).hasUnderstanding)
    }

    @Test fun should_rejectDelayedClaim_when_previousLessonHadNoIndependentEvidence() {
        var now = 1_000L
        val service = CoachCommandService(CoachFileStore(folder.newFolder()), listOf(course), clock = { now })
        val topic = command(service, "start_topic", text = "空课次不能充当复核基线").targetId
        val first = command(service, "start_lesson", topic).targetId
        command(service, "end_lesson", first)
        now += CoachTeachingProtocol.MIN_DELAY_MILLIS
        val second = command(service, "start_lesson", topic).targetId
        val payload = JSONObject().put("mode", "review").put("assessment", JSONObject()
            .put("dimension", "understanding").put("reviewOfSessionId", first)).toString()
        assertFalse(command(service, "coach_reply", second, "不能把首次验证称为延迟复核", payload).success)
    }

    @Test fun should_preservePendingAssessment_when_modelTriesToOpenNextLessonWithoutFinishing() {
        val service = service()
        val topic = command(service, "start_topic", text = "禁止跳过待评估").targetId
        val lesson = command(service, "start_lesson", topic).targetId
        command(service, "coach_reply", lesson, "说明机制", """{"mode":"practice","assessment":{"dimension":"understanding"}}""")
        val text = "我提交一段尚未评估的解释"
        command(service, "answer", lesson, text, user = CoachUserInput("attempt", text))
        val pending = service.state.value.sessions.single().pendingTurnId
        assertEquals(lesson, command(service, "start_lesson", topic).targetId)
        assertEquals(pending, service.state.value.sessions.single().pendingTurnId)
        assertFalse(command(service, "end_lesson", lesson).success)
    }

    @Test fun should_invalidateUnshownAssessment_when_finalReplyContainsDifferentQuestion() {
        val service = service()
        val topic = command(service, "start_topic", text = "题目与可见正文一致性").targetId
        service.bindTopicConversation(topic, "chat-visible")
        val lesson = command(service, "start_lesson", topic).targetId
        assertTrue(command(service, "coach_reply", lesson, "请解释事实和推断的区别",
            """{"mode":"practice","assessment":{"dimension":"understanding"}}""").success)
        assertTrue(service.recordConversationReply("chat-visible", "visible-question",
            "请给同事写一句礼貌回应。", lesson).success)
        val session = service.state.value.sessions.single()
        val prompt = session.turns.first()
        assertEquals("", prompt.originMessageId)
        assertTrue(prompt.sourceInvalidated)
        assertNull(session.assessment)
        assertEquals("请给同事写一句礼貌回应。", session.turns.last().text)
        val answer = "我会先确认你最关心什么"
        assertTrue(service.registerConversationUser("chat-visible", "answer", answer, lesson).success)
        assertFalse(command(service, "answer", lesson, answer,
            user = CoachUserInput("answer", answer, "chat-visible")).success)
        assertFalse(CoachTeachingProtocol.progress(service.state.value, topic).hasUnderstanding)
    }

    @Test fun should_rejectUnshownHostAssessment_beforeFinalMessageIsArchived() {
        val service = service()
        val topic = command(service, "start_topic", text = "最终题目归档前不可验证").targetId
        service.bindTopicConversation(topic, "chat-pending-question")
        val lesson = command(service, "start_lesson", topic).targetId
        command(service, "coach_reply", lesson, "请说明机制",
            """{"mode":"practice","assessment":{"dimension":"understanding"}}""")
        val text = "事实能核对，推断需要假设"
        assertFalse(command(service, "answer", lesson, text,
            user = CoachUserInput("too-early", text, "chat-pending-question")).success)
        assertTrue(service.recordConversationReply("chat-pending-question", "question-final",
            "请说明机制，再用自己的例子解释。", lesson).success)
        assertTrue(command(service, "answer", lesson, text,
            user = CoachUserInput("after-final", text, "chat-pending-question")).success)
        val turn = service.state.value.sessions.single().turns.last()
        assertTrue(command(service, "coach_reply", lesson, "原话支持这项理解证据。", evidence(turn, "understanding")).success)
        assertTrue(CoachTeachingProtocol.progress(service.state.value, topic).hasUnderstanding)
    }

    @Test fun should_bindOnlyTextActuallyPresent_when_multipleToolTurnsPrecedeFinalReply() {
        val service = service()
        val topic = command(service, "start_topic", text = "多段工具文字的来源").targetId
        service.bindTopicConversation(topic, "chat-multiple")
        val lesson = command(service, "start_lesson", topic).targetId
        command(service, "coach_reply", lesson, "未对用户展示的背景解释", """{"mode":"explain"}""")
        command(service, "coach_reply", lesson, "请解释事实和推断", """{"mode":"practice","assessment":{"dimension":"understanding"}}""")
        val finalText = "我们换个方式：请解释事实和推断，并举例。"
        assertTrue(service.recordConversationReply("chat-multiple", "final", finalText, lesson).success)
        val turns = service.state.value.sessions.single().turns
        assertEquals("", turns.first().originMessageId)
        assertEquals("final", turns[1].originMessageId)
        assertEquals("final", turns.last().originMessageId)
        assertNotNull(service.state.value.sessions.single().assessment)
        assertTrue(service.recordConversationReply("chat-multiple", "final", finalText, lesson).success)
    }

    @Test fun should_rejectExistingIncorrectSourceBinding_when_finalTextDoesNotContainQuestion() {
        val topic = CoachTopic("topic", course.id, "1.1", "旧错误绑定", "校验实际正文", chatSessionId = "chat")
        val prompt = CoachTurn("prompt", "coach", "请解释事实和推断", "practice",
            originMessageId = "assistant", purpose = "assessment", assessmentId = "question", dimension = "understanding")
        val actual = CoachTurn("final", "coach", "请给同事写一句礼貌回应", "practice",
            originMessageId = "assistant", purpose = "teaching")
        val answer = CoachTurn("answer", "user", "事实可核对而推断需要假设", "practice",
            purpose = "attempt", assessmentId = "question", dimension = "understanding")
        val session = CoachSession("lesson", course, "1.1", topicId = topic.id,
            teachingProtocol = CoachTeachingProtocol.VERSION, chatSessionId = "chat", turns = listOf(prompt, actual, answer),
            evidence = listOf(CoachEvidence("understanding", answer.id, answer.text, "解释机制", true)))
        val state = CoachState(topics = listOf(topic), tracks = listOf(CoachTrack(course)), sessions = listOf(session))
        assertFalse(CoachTeachingProtocol.progress(state, topic.id).hasUnderstanding)
    }

    private fun saveEvidence(service: CoachCommandService, sessionId: String, dimension: String, prompt: String, text: String) {
        assertTrue(command(service, "coach_reply", sessionId, prompt, JSONObject().put("mode", "practice")
            .put("assessment", JSONObject().put("dimension", dimension)).toString()).success)
        val chatId = service.state.value.sessions.single { it.id == sessionId }.chatSessionId
        if (chatId.isNotBlank()) {
            assertTrue(service.recordConversationReply(chatId, UUID.randomUUID().toString(), prompt, sessionId).success)
        }
        assertTrue(command(service, "answer", sessionId, text, user = CoachUserInput(UUID.randomUUID().toString(), text)).success)
        val turn = service.state.value.sessions.last().turns.last()
        val result = command(service, "coach_reply", sessionId, "已保存这段说明的证据。", evidence(turn, dimension))
        assertTrue(result.message, result.success)
    }

    private fun evidence(turn: CoachTurn, criterion: String): String = JSONObject().put("mode", "explain")
        .put("requestTurnId", turn.id).put("evidence", org.json.JSONArray().put(JSONObject()
            .put("criterionId", criterion).put("turnId", turn.id).put("quote", turn.text)
            .put("reason", "原话说明了该项标准的具体机制或行动").put("met", true))).toString()
}
