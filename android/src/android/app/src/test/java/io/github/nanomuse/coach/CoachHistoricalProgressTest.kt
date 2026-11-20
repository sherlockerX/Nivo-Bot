package io.github.nanomuse.coach

import java.io.File
import java.time.ZoneId
import java.util.UUID
import kotlinx.serialization.json.Json
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/** 通过真实命令积累跨单元证据，核验来源撤销和档案删除后的持久进度。 */
class CoachHistoricalProgressTest {
    @get:Rule val folder = TemporaryFolder()
    private val zone = ZoneId.of("UTC")
    private var now = 1_795_010_400_000L
    private val course = CoachCourse("history", "长期技能", "书房", CoachKind.JUDGMENT,
        (1..3).map { number -> CoachUnit(number.toString(), "单元$number", "解释并应用", "独立练习",
            listOf(CoachCriterion("understanding", "解释机制"), CoachCriterion("application", "独立应用")), "自拟") },
        "v2", "自拟")

    @Test fun should_revokeOldUnit_when_messageIsInvalidatedAfterTopicRetargets() {
        val service = service()
        val topic = startTopic(service, "long-chat")
        val firstApplication = demonstrate(service, topic)
        moveNext(service, topic)
        demonstrate(service, topic)
        assertEquals(setOf("1", "2", "3"), demonstrated(service))

        assertTrue(service.invalidateMessage("long-chat", firstApplication, "原话被删除").success)

        assertEquals(setOf("2", "3"), demonstrated(service))
        assertEquals("2", service.state.value.topics.single().unitId)
    }

    @Test fun should_revokeAllHistoricalUnits_when_conversationIsArchived() {
        val service = service()
        val topic = startTopic(service, "archive-chat")
        demonstrate(service, topic)
        moveNext(service, topic)
        demonstrate(service, topic)

        assertTrue(service.invalidateConversation("archive-chat", "聊天已删除").success)

        assertEquals(setOf("3"), demonstrated(service))
        assertEquals("archived", service.state.value.topics.single().status)
    }

    @Test fun should_recomputeAllDeletedUnits_andKeepAnotherTopicsIndependentEvidence_when_purged() {
        val service = service()
        val removed = startTopic(service, "remove-chat")
        demonstrate(service, removed)
        moveNext(service, removed)
        demonstrate(service, removed)
        val retained = startTopic(service, "retain-chat", "1")
        demonstrate(service, retained)

        assertTrue(service.purgeConversation("remove-chat").success)

        assertEquals(setOf("1", "3"), demonstrated(service))
        assertEquals(listOf(retained), service.state.value.topics.map { it.id })
        assertTrue(service.state.value.sessions.all { it.topicId == retained })
    }

    @Test fun should_preserveLegacyProgress_when_oldCourseSessionsArePurged() {
        val directory = folder.newFolder()
        val oldCourse = course.copy(version = "v1")
        val oldTopic = CoachTopic("old-topic", course.id, "3", "旧版专题", "旧案例", chatSessionId = "old-chat")
        val oldSession = CoachSession("old-session", oldCourse, "3", topicId = oldTopic.id,
            teachingProtocol = CoachTeachingProtocol.VERSION, status = "complete")
        CoachFileStore(directory).save(CoachState(tracks = listOf(CoachTrack(course, demonstrated = setOf("3"))),
            topics = listOf(oldTopic), sessions = listOf(oldSession)))
        val service = CoachCommandService(CoachFileStore(directory), listOf(course), clock = { now })
        val currentTopic = startTopic(service, "current-chat")
        demonstrate(service, currentTopic)
        moveNext(service, currentTopic)
        assertEquals(setOf("1", "3"), demonstrated(service))

        assertTrue(service.purgeConversation("old-chat").success)

        assertEquals(setOf("1", "3"), demonstrated(service))
        assertEquals(listOf(currentTopic), service.state.value.topics.map { it.id })
        // 同一长期专题内混有旧版本单元，也不能把该旧单元纳入当前删除范围。
        CoachFileStore(directory).save(service.state.value.copy(sessions = service.state.value.sessions +
            oldSession.copy(id = "mixed-old-version", topicId = currentTopic, chatSessionId = "current-chat")))
        val restored = CoachCommandService(CoachFileStore(directory), listOf(course), clock = { now })
        assertTrue(restored.purgeConversation("current-chat").success)
        assertEquals(setOf("3"), demonstrated(restored))
    }

    @Test fun should_removeDerivedPlansAndTheirReplayRecords_fromBothSnapshots_when_purged() {
        val directory = folder.newFolder()
        val otherCourse = course.copy(id = "other", title = "其他技能")
        val service = CoachCommandService(CoachFileStore(directory), listOf(course, otherCourse), clock = { now }, zone = { zone })
        val topic = startTopic(service, "private-chat")
        val quote = "只属于待删除档案的秘密原话"
        val lesson = service.registerConversationUser("private-chat", "private-user", quote).targetId
        val source = service.state.value.sessions.single().turns.single()
        command(service, "end_lesson", lesson)
        val base = CoachSkillProfile.basePlan(service.state.value, course.id, CoachDay.key(now, zone), zone, 10, "", now)
        val cited = base.copy(id = "cited", basis = listOf(CoachPlanBasis(lesson, source.id, quote)), reason = quote)
        adopt(service, cited)
        val next = command(service, "start_lesson", topic).targetId
        assertEquals(cited.id, service.state.value.sessions.single { it.id == next }.planId)
        // 备课模型可能把历史原话写进正文却漏列basis，因此本技能的派生教案都需失效。
        val uncited = base.copy(id = "uncited", coachNotes = quote, createdAt = now + 1)
        adopt(service, uncited)
        val other = CoachSkillProfile.basePlan(service.state.value, otherCourse.id, CoachDay.key(now, zone), zone, 10, "", now)
            .copy(id = "retained-plan")
        adopt(service, other)

        assertTrue(service.purgeConversation("private-chat").success)

        assertEquals(listOf(other), service.state.value.plans)
        assertTrue(service.state.value.operations.values.none { it.substringAfter('|') in setOf(cited.id, uncited.id) })
        listOf("state.json", "state.backup.json").forEach { filename ->
            assertFalse(filename, File(directory, filename).readText().contains(quote))
        }
        val reloaded = CoachCommandService(CoachFileStore(directory), listOf(course, otherCourse), clock = { now }, zone = { zone })
        assertEquals(service.state.value, reloaded.state.value)
        val fresh = startTopic(reloaded, "fresh-chat")
        val freshLesson = command(reloaded, "start_lesson", fresh).targetId
        assertEquals("", reloaded.state.value.sessions.single { it.id == freshLesson }.planId)
    }

    private fun service(): CoachCommandService {
        val files = CoachFileStore(folder.newFolder())
        files.save(CoachState(tracks = listOf(CoachTrack(course, demonstrated = setOf("3")))))
        return CoachCommandService(files, listOf(course), clock = { now }, zone = { zone })
    }

    private fun demonstrated(service: CoachCommandService): Set<String> = service.state.value.tracks.single().demonstrated

    private fun startTopic(service: CoachCommandService, chat: String, unitId: String = "1"): String {
        val topic = command(service, "start_topic", course.id, chat, JSONObject().put("unitId", unitId).toString()).targetId
        assertTrue(service.bindTopicConversation(topic, chat).success)
        return topic
    }

    private fun moveNext(service: CoachCommandService, topic: String) {
        command(service, "advance", course.id)
        command(service, "retarget_topic", topic)
    }

    private fun demonstrate(service: CoachCommandService, topic: String): String {
        val first = command(service, "start_lesson", topic).targetId
        saveEvidence(service, first, "understanding")
        val applicationSource = saveEvidence(service, first, "application")
        command(service, "end_lesson", first)
        now += CoachTeachingProtocol.MIN_DELAY_MILLIS
        val delayed = command(service, "start_lesson", topic).targetId
        saveEvidence(service, delayed, "understanding", first)
        command(service, "end_lesson", delayed)
        assertTrue(CoachTeachingProtocol.progress(service.state.value, topic).isDemonstrated)
        return applicationSource
    }

    private fun saveEvidence(service: CoachCommandService, lesson: String, dimension: String, reviewOf: String = ""): String {
        val assessment = JSONObject().put("dimension", dimension)
        if (reviewOf.isNotEmpty()) assessment.put("reviewOfSessionId", reviewOf)
        val question = "独立说明$dimension，课节$lesson"
        command(service, "coach_reply", lesson, question,
            JSONObject().put("mode", "practice").put("assessment", assessment).toString())
        val chat = service.state.value.sessions.single { it.id == lesson }.chatSessionId
        assertTrue(service.recordConversationReply(chat, UUID.randomUUID().toString(), question, lesson).success)
        val text = "这是我对${dimension}的独立解释与具体行动"
        val messageId = UUID.randomUUID().toString()
        command(service, "answer", lesson, text, user = CoachUserInput(messageId, text, chat))
        val turn = service.state.value.sessions.single { it.id == lesson }.turns.last()
        val evidence = JSONObject().put("mode", "explain").put("requestTurnId", turn.id)
            .put("evidence", JSONArray().put(JSONObject().put("criterionId", dimension).put("turnId", turn.id)
                .put("quote", text).put("reason", "原话给出了对应机制或行动").put("met", true)))
        command(service, "coach_reply", lesson, "已记录独立证据", evidence.toString())
        return messageId
    }

    private fun adopt(service: CoachCommandService, plan: CoachLessonPlan) {
        command(service, "adopt_plan", plan.courseId, payload = Json.encodeToString(CoachLessonPlan.serializer(), plan))
    }

    private fun command(service: CoachCommandService, action: String, target: String, text: String = "",
        payload: String = "", user: CoachUserInput? = null): CoachResult = service.execute(CoachCommand(action,
        UUID.randomUUID().toString(), service.state.value.revision, target, text, payload), user).also {
            assertTrue("$action: ${it.message}", it.success)
        }
}
