package io.github.nanomuse.coach

import java.time.ZoneId
import java.util.UUID
import kotlinx.serialization.json.Json
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/** 技能档案：一项技能一个长期专题，课节按日期分节，教案经宿主校验才采用。 */
class CoachSkillProfileTest {
    @get:Rule val folder = TemporaryFolder()
    private val zone = ZoneId.of("Asia/Shanghai")
    private val course = CoachCourse("judgment", "独立判断", "书房", CoachKind.JUDGMENT, listOf(
        CoachUnit("1", "区分事实", "区分事实和推断", "案例教学", listOf(CoachCriterion("understanding", "解释机制"),
            CoachCriterion("application", "独立回应")), "自拟练习"),
        CoachUnit("2", "回应追问", "在追问中说明理由", "角色演练", listOf(CoachCriterion("understanding", "解释机制"),
            CoachCriterion("application", "独立回应")), "自拟练习")), "v1", "自拟练习")
    // 2026-11-18 22:00 上海时间
    private var now = 1_795_010_400_000L
    private val json = Json { encodeDefaults = true }

    private fun service() = CoachCommandService(CoachFileStore(folder.newFolder()), listOf(course), clock = { now }, zone = { zone })

    private fun command(service: CoachCommandService, action: String, target: String = "judgment", text: String = "",
        payload: String = "", user: CoachUserInput? = null) = service.execute(CoachCommand(action, UUID.randomUUID().toString(),
        service.state.value.revision, target, text, payload), user)

    private fun today() = CoachDay.key(now, zone)

    @Test fun should_dateLessonsInPhoneZone_andOfferChoice_when_earlierLessonUnfinished() {
        val service = service()
        val topic = command(service, "start_topic").targetId
        val first = command(service, "start_lesson", topic).targetId
        val lesson = service.state.value.sessions.single()
        assertEquals("2026-11-18", lesson.localDate)
        assertEquals("Asia/Shanghai", lesson.zoneId)
        assertEquals(CoachTodayState.IN_PROGRESS, CoachSkillProfile.today(service.state.value, "judgment", today(), zone).state)
        // 次日8点：昨晚的课节没练完，需要用户选择
        now += 10 * 3_600_000L
        assertEquals("2026-11-19", today())
        assertEquals(CoachTodayState.EARLIER_UNFINISHED, CoachSkillProfile.today(service.state.value, "judgment", today(), zone).state)
        // 重复开课只续原课节，不产生第二节
        assertEquals(first, command(service, "start_lesson", topic).targetId)
        assertTrue(command(service, "save_input", first, "昨天写了一半").success)
        assertTrue(command(service, "seal_lesson", first).success)
        val second = command(service, "start_lesson", topic).targetId
        assertNotEquals(first, second)
        val sealed = service.state.value.sessions.single { it.id == first }
        assertEquals("sealed", sealed.status)
        assertEquals("昨天写了一半", sealed.draft)
        assertEquals("2026-11-18", sealed.localDate)
        assertEquals("2026-11-19", service.state.value.sessions.single { it.id == second }.localDate)
        assertEquals(CoachTodayState.IN_PROGRESS, CoachSkillProfile.today(service.state.value, "judgment", today(), zone).state)
    }

    @Test fun should_reportDone_andStartExtraLessonOnSameDay() {
        val service = service()
        val topic = command(service, "start_topic").targetId
        val first = command(service, "start_lesson", topic).targetId
        assertTrue(command(service, "end_lesson", first, "今天练完了").success)
        val facts = CoachSkillProfile.today(service.state.value, "judgment", today(), zone)
        assertEquals(CoachTodayState.DONE, facts.state)
        assertEquals(1, facts.lessonsToday.size)
        val extra = command(service, "start_lesson", topic).targetId
        assertNotEquals(first, extra)
        assertEquals(2, CoachSkillProfile.today(service.state.value, "judgment", today(), zone).lessonsToday.size)
    }

    @Test fun should_keepOneTopicPerSkill_whenUnitAdvances() {
        val service = service()
        val topic = command(service, "start_topic", payload = """{"title":"独立判断"}""").targetId
        service.bindTopicConversation(topic, "skill-chat")
        val lesson = command(service, "start_lesson", topic).targetId
        // 单元未变时是空操作；单元变了但还有进行中的课节时不换
        assertTrue(command(service, "retarget_topic", topic).success)
        val withOpen = service.state.value.let { it.copy(tracks = it.tracks.map { track -> track.copy(currentUnitId = "2") }) }
        assertTrue(runCatching { CoachTopicCommands.apply(withOpen, CoachCommand("retarget_topic", "op", 0, topic), now, zone) }.isFailure)
        assertTrue(command(service, "end_lesson", lesson).success)
        // 模拟用户已推进到第二单元
        val advanced = service.state.value.let { it.copy(tracks = it.tracks.map { track -> track.copy(currentUnitId = "2") }) }
        val moved = CoachTopicCommands.apply(advanced, CoachCommand("retarget_topic", "op", 0, topic), now, zone).first
        val kept = moved.topics.single()
        assertEquals("2", kept.unitId)
        assertEquals("skill-chat", kept.chatSessionId)
        assertEquals(topic, CoachSkillProfile.topic(moved, "judgment")!!.id)
        val next = CoachTopicCommands.startLesson(moved, topic, now, zone).first
        assertEquals("1", next.sessions.first().unitId)
        assertEquals("2", next.sessions.last().unitId)
        assertEquals("skill-chat", next.sessions.last().chatSessionId)
    }

    @Test fun should_adoptValidPlan_bindItToNewLesson_andRejectStaleOrInvented() {
        val service = service()
        val topic = command(service, "start_topic").targetId
        val base = CoachSkillProfile.basePlan(service.state.value, "judgment", today(), zone, 10, "", now)
        assertEquals(CoachSkillProfile.NEXT_DIAGNOSE, base.nextKind)
        assertTrue(command(service, "adopt_plan", payload = json.encodeToString(CoachLessonPlan.serializer(), base)).success)
        val invented = base.copy(id = "p2", criteriaIds = listOf("made-up"), createdAt = now + 1)
        assertFalse(command(service, "adopt_plan", payload = json.encodeToString(CoachLessonPlan.serializer(), invented)).success)
        val fakeQuote = base.copy(id = "p3", createdAt = now + 1, basis = listOf(CoachPlanBasis("nope", "nope", "我从没说过")))
        assertFalse(command(service, "adopt_plan", payload = json.encodeToString(CoachLessonPlan.serializer(), fakeQuote)).success)
        val newer = base.copy(id = "p4", task = "新的任务", createdAt = now + 5)
        assertTrue(command(service, "adopt_plan", payload = json.encodeToString(CoachLessonPlan.serializer(), newer)).success)
        // 迟到的旧结果不能覆盖较新的教案
        val late = base.copy(id = "p5", createdAt = now + 2)
        assertFalse(command(service, "adopt_plan", payload = json.encodeToString(CoachLessonPlan.serializer(), late)).success)
        assertEquals(listOf("superseded", "adopted"), service.state.value.plans.map { it.status })
        val lesson = command(service, "start_lesson", topic).targetId
        assertEquals("p4", service.state.value.sessions.single { it.id == lesson }.planId)
        assertEquals("p4", CoachSkillProfile.today(service.state.value, "judgment", today(), zone).plan!!.id)
    }

    @Test fun should_requirePreparedPlanFields_whenFromPrepAgent() {
        val service = service()
        val base = CoachSkillProfile.basePlan(service.state.value, "judgment", today(), zone, 10, "", now)
        val prepared = base.copy(id = "prep", source = "prep_agent")
        assertFalse(command(service, "adopt_plan", payload = json.encodeToString(CoachLessonPlan.serializer(), prepared)).success)
        val complete = prepared.copy(reason = "还没有基线", observe = "能否区分事实与推断", check = "换一个陌生会议场景",
            hints = listOf("先列出可核对的事实"), branches = listOf("若混在一起，先给最小样例"))
        assertTrue(command(service, "adopt_plan", payload = json.encodeToString(CoachLessonPlan.serializer(), complete)).success)
    }

    @Test fun should_notAcceptHostOnlyActions_fromModelTools() {
        val service = service()
        val bridge = CoachAgentBridge({ service.state.value }) { command, user -> service.execute(command, user) }
        listOf("adopt_plan", "seal_lesson", "retarget_topic").forEach { action ->
            val result = bridge.command("""{"action":"$action","operationId":"op-$action","expectedRevision":0,"targetId":"judgment"}""", null)
            assertFalse(action, result.success)
        }
        assertTrue(service.state.value.plans.isEmpty())
    }

    @Test fun should_explainNextStep_fromIndependentOrHintedAttempt() {
        val service = service()
        val topic = command(service, "start_topic").targetId
        val lesson = command(service, "start_lesson", topic).targetId
        assertEquals(CoachSkillProfile.NEXT_DIAGNOSE, CoachSkillProfile.nextStep(service.state.value, "judgment", now).kind)
        // 提示后完成：下次先验证独立完成
        command(service, "coach_reply", lesson, "解释机制", """{"mode":"practice","assessment":{"dimension":"understanding"}}""")
        assertTrue(command(service, "request_hint", lesson).success)
        val hinted = "根据提示解释机制"
        assertTrue(command(service, "answer", lesson, hinted, user = CoachUserInput("hinted", hinted)).success)
        val step = CoachSkillProfile.nextStep(service.state.value, "judgment", now)
        assertEquals(CoachSkillProfile.NEXT_INDEPENDENT_FIRST, step.kind)
        assertEquals(hinted, step.basis!!.quote)
        assertEquals("hinted", CoachSkillProfile.performance(service.state.value, "judgment", now)
            .single { it.dimension == "understanding" }.status)
        // 独立完成：下次换情境
        val turn = service.state.value.sessions.single().turns.last()
        assertTrue(command(service, "coach_reply", lesson, "继续", JSONObject().put("mode", "explain").put("requestTurnId", turn.id).toString()).success)
        assertTrue(command(service, "coach_reply", lesson, "请独立说明事实和推断的区别",
            """{"mode":"practice","assessment":{"dimension":"understanding"}}""").success)
        val own = "事实能核对，推断依赖假设"
        assertTrue(command(service, "answer", lesson, own, user = CoachUserInput("own", own)).success)
        val ownTurn = service.state.value.sessions.single().turns.last()
        val evidence = JSONObject().put("mode", "explain").put("requestTurnId", ownTurn.id).put("evidence", org.json.JSONArray()
            .put(JSONObject().put("criterionId", "understanding").put("turnId", ownTurn.id).put("quote", own)
                .put("reason", "原话说明了机制").put("met", true))).toString()
        assertTrue(command(service, "coach_reply", lesson, "你独立说明了区别。", evidence).success)
        assertEquals(CoachSkillProfile.NEXT_NEW_SCENARIO, CoachSkillProfile.nextStep(service.state.value, "judgment", now).kind)
        assertEquals("independent", CoachSkillProfile.performance(service.state.value, "judgment", now)
            .single { it.dimension == "understanding" }.status)
    }

    @Test fun should_parsePlanFromModelText_keepingHostIdentity() {
        val service = service()
        val base = CoachSkillProfile.basePlan(service.state.value, "judgment", today(), zone, 10, "组会", now)
        val text = """好的，教案如下：
            {"task":"和坚持原方案的同事讨论五分钟","reason":"还没有基线","observe":"能否说出改变判断的信息",
             "concepts":["事实与推断"],"materials":[{"title":"自拟讨论","origin":"self_authored"},{"title":"某本书","origin":"verified"}],
             "hints":["先列事实"],"branches":["若两次都改口，追问哪条信息改变了判断"],"check":"换陌生场景",
             "criteriaIds":["understanding"],"coachNotes":"参考解答","basis":[],"courseId":"other","localDate":"1999-01-01"}"""
        val plan = CoachLessonPrep.parse(text, base)
        assertEquals("judgment", plan.courseId)
        assertEquals(today(), plan.localDate)
        assertEquals("prep_agent", plan.source)
        assertEquals("unverified", plan.materials.last().origin)
        assertEquals("组会", plan.need)
        CoachLessonPlanRules.validate(service.state.value, plan)
    }
}
