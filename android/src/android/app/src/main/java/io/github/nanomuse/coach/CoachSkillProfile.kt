package io.github.nanomuse.coach

import java.time.Instant
import java.time.ZoneId
import java.util.UUID

/** 课节日期键使用设备当前时区的本地日期。 */
object CoachDay {
    /** 某一时刻在给定时区下的日期，格式为 yyyy-MM-dd。 */
    fun key(now: Long, zone: ZoneId): String = Instant.ofEpochMilli(now).atZone(zone).toLocalDate().toString()

    /** 旧课节没有日期字段时按开始时间推算，仍无法推算则返回空串。 */
    fun of(session: CoachSession, zone: ZoneId): String = session.localDate.ifBlank {
        if (session.startedAt > 0) key(session.startedAt, zone) else ""
    }
}

/** 教练页主按钮的四种状态。 */
enum class CoachTodayState { NOT_STARTED, IN_PROGRESS, EARLIER_UNFINISHED, DONE }

/** 今日训练卡所需的事实：当前课节、今天的课节数和今天采用的教案。 */
data class CoachToday(
    val state: CoachTodayState,
    val openLesson: CoachSession?,
    val lessonsToday: List<CoachSession>,
    val plan: CoachLessonPlan?,
)

/** 一条可打开的证据：原话、时间、提示量和情境。 */
data class CoachEvidenceRef(
    val sessionId: String, val turnId: String, val messageId: String, val chatSessionId: String,
    val quote: String, val reason: String, val at: Long, val support: String, val context: String,
)

/** 表现项按维度给出状态，不用一个分数概括整项技能。 */
data class CoachPerformanceItem(val dimension: String, val status: String, val evidence: CoachEvidenceRef?,
    val dueAt: Long = 0)

/** 下次安排的规则种类与触发它的那条记录。 */
data class CoachNextStep(val kind: String, val basis: CoachEvidenceRef?)

/** 技能档案的只读推导，页面、备课和旁聊共用同一套规则。 */
object CoachSkillProfile {
    val OPEN_STATUSES = setOf("active", "paused", "waiting_real")

    // 下次安排的种类，对应PRD中调整计划的规则表。
    const val NEXT_DIAGNOSE = "diagnose"
    const val NEXT_NEW_SCENARIO = "new_scenario"
    const val NEXT_INDEPENDENT_FIRST = "independent_first"
    const val NEXT_DELAYED_REVIEW = "delayed_review"
    const val NEXT_WAIT_REVIEW = "wait_review"
    const val NEXT_REAL_ACTION = "real_action"
    const val NEXT_DISPUTED = "disputed"
    const val NEXT_ADVANCE = "advance"
    const val NEXT_CONTINUE = "continue"

    /** 技能的长期训练专题：优先已经绑定聊天的那一个，保证一项技能一条旁聊。 */
    fun topic(state: CoachState, courseId: String): CoachTopic? {
        val active = state.topics.filter { it.courseId == courseId && it.status == "active" }
        return active.lastOrNull { it.chatSessionId.isNotBlank() } ?: active.lastOrNull()
    }

    /** 当前课程版本下属于该技能的新协议课节，按开始时间排列。 */
    fun lessons(state: CoachState, courseId: String): List<CoachSession> {
        val track = state.tracks.singleOrNull { it.course.id == courseId } ?: return emptyList()
        return state.sessions.filter { it.course.id == courseId && it.teachingProtocol == CoachTeachingProtocol.VERSION &&
            it.course.version == track.course.version && !it.requiresCourseReview }
    }

    /** 判断今天该开始、继续、在两天之间选择，还是查看结果。 */
    fun today(state: CoachState, courseId: String, today: String, zone: ZoneId): CoachToday {
        val topic = topic(state, courseId)
        val open = topic?.activeSessionId?.let { id -> state.sessions.singleOrNull { it.id == id } }
            ?.takeIf { it.status in OPEN_STATUSES && !it.requiresCourseReview }
        val todays = state.sessions.filter { it.course.id == courseId && it.teachingProtocol == CoachTeachingProtocol.VERSION &&
            CoachDay.of(it, zone) == today }
        val plan = state.plans.lastOrNull { it.courseId == courseId && it.localDate == today && it.status == "adopted" }
        val openDate = open?.let { CoachDay.of(it, zone) }
        val kind = when {
            open != null && (openDate.isNullOrBlank() || openDate == today) -> CoachTodayState.IN_PROGRESS
            open != null -> CoachTodayState.EARLIER_UNFINISHED
            todays.any { it.status == "complete" || it.status == "sealed" } -> CoachTodayState.DONE
            else -> CoachTodayState.NOT_STARTED
        }
        return CoachToday(kind, open, todays, plan)
    }

    /** 当前单元的理解、应用和延迟复核三项表现，各自附最近一条依据。 */
    fun performance(state: CoachState, courseId: String, now: Long): List<CoachPerformanceItem> {
        val track = state.tracks.singleOrNull { it.course.id == courseId } ?: return emptyList()
        val unit = track.course.units.singleOrNull { it.id == track.currentUnitId } ?: return emptyList()
        val lessons = lessons(state, courseId).filter { it.unitId == unit.id }
        val dimensions = unit.criteria.map(CoachTeachingProtocol::dimension).filter { it.isNotBlank() }.distinct()
        val items = dimensions.map { dimension ->
            val valid = latestValid(lessons, dimension)
            val hinted = if (valid == null) latestAttempt(lessons, dimension) else null
            when {
                valid != null -> CoachPerformanceItem(dimension, "independent", valid)
                hinted != null -> CoachPerformanceItem(dimension, if (hinted.support == "hinted") "hinted" else "attempted", hinted)
                else -> CoachPerformanceItem(dimension, "none", null)
            }
        }
        val delayed = lessons.firstNotNullOfOrNull { session ->
            session.evidence.lastOrNull { evidence -> evidence.met && !evidence.disputed &&
                session.turns.any { it.id == evidence.turnId && CoachTeachingProtocol.isValidDelayedReview(state, session, it) } &&
                runCatching { CoachTeachingProtocol.validateEvidence(session, evidence) }.isSuccess
            }?.let { ref(session, it) }
        }
        val reviewItem = when {
            delayed != null -> CoachPerformanceItem("delayed", "independent", delayed)
            else -> {
                val eligible = lessons.filter { it.status == "complete" && it.endedAt > 0 &&
                    dimensions.any { dimension -> CoachTeachingProtocol.hasImmediateEvidence(it, dimension) } }
                    .minByOrNull { it.endedAt }
                if (eligible == null) CoachPerformanceItem("delayed", "none", null)
                else CoachPerformanceItem("delayed", if (now - eligible.endedAt >= CoachTeachingProtocol.MIN_DELAY_MILLIS) "due" else "waiting",
                    null, eligible.endedAt + CoachTeachingProtocol.MIN_DELAY_MILLIS)
            }
        }
        return items + reviewItem
    }

    /** 按最近一次真实作答决定下次怎样练；没有作答时先诊断。时间相同时以记录顺序为准。 */
    fun nextStep(state: CoachState, courseId: String, now: Long): CoachNextStep {
        val track = state.tracks.singleOrNull { it.course.id == courseId } ?: return CoachNextStep(NEXT_DIAGNOSE, null)
        val lessons = lessons(state, courseId).filter { it.unitId == track.currentUnitId }
        if (track.currentUnitId in track.demonstrated) return CoachNextStep(NEXT_ADVANCE, null)
        val waiting = state.actions.lastOrNull { action -> action.status in setOf("planned", "deferred") &&
            lessons.any { it.id == action.sessionId } }
        if (waiting != null) return CoachNextStep(NEXT_REAL_ACTION, null)
        val disputed = lessons.asReversed().firstNotNullOfOrNull { session ->
            session.evidence.lastOrNull { it.disputed }?.let { ref(session, it) } }
        val attempt = lessons.flatMap { session -> session.turns.filter { it.role == "user" && it.purpose == "attempt" &&
            !it.sourceInvalidated }.map { session to it } }.sortedBy { it.second.createdAt }.lastOrNull()
        if (disputed != null && (attempt == null || attempt.second.createdAt <= disputed.at)) return CoachNextStep(NEXT_DISPUTED, disputed)
        if (attempt == null) return CoachNextStep(NEXT_DIAGNOSE, null)
        val (session, turn) = attempt
        val evidence = session.evidence.lastOrNull { it.turnId == turn.id }
        val basis = evidence?.let { ref(session, it) } ?: turnRef(session, turn)
        val independent = evidence != null && evidence.met && !evidence.disputed &&
            runCatching { CoachTeachingProtocol.validateEvidence(session, evidence) }.isSuccess
        if (!independent) return CoachNextStep(if (turn.support == "hinted") NEXT_INDEPENDENT_FIRST else NEXT_CONTINUE, basis)
        val review = performance(state, courseId, now).singleOrNull { it.dimension == "delayed" }
        val dimensionsMet = performance(state, courseId, now).filter { it.dimension != "delayed" }.all { it.status == "independent" }
        return when {
            dimensionsMet && review?.status == "due" -> CoachNextStep(NEXT_DELAYED_REVIEW, basis)
            dimensionsMet && review?.status == "waiting" -> CoachNextStep(NEXT_WAIT_REVIEW, basis)
            else -> CoachNextStep(NEXT_NEW_SCENARIO, basis)
        }
    }

    /** 模型不可用或校验失败时使用的基础练习：只取当前单元已审核的标准与方法。 */
    fun basePlan(state: CoachState, courseId: String, today: String, zone: ZoneId, minutes: Int, need: String,
        now: Long, reason: String = ""): CoachLessonPlan {
        val track = state.track(courseId)
        val unit = track.course.units.single { it.id == track.currentUnitId }
        val next = nextStep(state, courseId, now)
        return CoachLessonPlan(UUID.randomUUID().toString(), courseId, unit.id, track.course.version, today, zone.id,
            minutes, need.take(600), next.kind, task = unit.focus.take(1200), observe = unit.criteria.joinToString("\n") { it.description }.take(1200),
            materials = listOfNotNull(unit.source.takeIf { it.isNotBlank() }?.let { CoachPlanMaterial(it.take(300), "course") }),
            check = unit.criteria.firstOrNull { CoachTeachingProtocol.dimension(it) == "application" }?.description.orEmpty().take(600),
            criteriaIds = unit.criteria.map { it.id }, basis = listOfNotNull(next.basis?.let { CoachPlanBasis(it.sessionId, it.turnId, it.quote.take(300)) }),
            source = "base", degradeReason = reason, createdAt = now, inputRevision = state.revision)
    }

    private fun latestValid(lessons: List<CoachSession>, dimension: String): CoachEvidenceRef? = lessons.flatMap { session ->
        session.evidence.filter { evidence -> evidence.met && !evidence.disputed &&
            session.turns.any { it.id == evidence.turnId && it.dimension == dimension } &&
            runCatching { CoachTeachingProtocol.validateEvidence(session, evidence) }.isSuccess }.map { ref(session, it) }
    }.sortedBy { it.at }.lastOrNull()

    private fun latestAttempt(lessons: List<CoachSession>, dimension: String): CoachEvidenceRef? = lessons.flatMap { session ->
        session.turns.filter { it.role == "user" && it.purpose == "attempt" && it.dimension == dimension && !it.sourceInvalidated }
            .map { turnRef(session, it) }
    }.sortedBy { it.at }.lastOrNull()

    private fun ref(session: CoachSession, evidence: CoachEvidence): CoachEvidenceRef {
        val turn = session.turns.single { it.id == evidence.turnId }
        return CoachEvidenceRef(session.id, turn.id, turn.originMessageId, session.chatSessionId, evidence.quote,
            evidence.reason, turn.createdAt, turn.support, turn.context)
    }

    private fun turnRef(session: CoachSession, turn: CoachTurn) = CoachEvidenceRef(session.id, turn.id, turn.originMessageId,
        session.chatSessionId, turn.text.take(300), "", turn.createdAt, turn.support, turn.context)
}

/** 宿主对教案的全部校验；备课结果与基础练习都要通过这里才能采用。 */
object CoachLessonPlanRules {
    val ORIGINS = setOf("course", "user", "self_authored", "unverified")
    private val DATE = Regex("""\d{4}-\d{2}-\d{2}""")

    /** 校验失败抛出带原因的异常，调用方据此修复一次或降级。 */
    fun validate(state: CoachState, plan: CoachLessonPlan) {
        val track = state.track(plan.courseId)
        require(plan.courseVersion == track.course.version) { "stale_course_version" }
        require(plan.unitId == track.currentUnitId) { "stale_unit" }
        val unit = track.course.units.singleOrNull { it.id == plan.unitId } ?: error("plan_unit_missing")
        require(DATE.matches(plan.localDate)) { "plan_date_invalid" }
        require(plan.minutes in 3..120) { "plan_minutes_invalid" }
        require(plan.task.isNotBlank() && plan.task.length <= 1200) { "plan_task_invalid" }
        require(plan.criteriaIds.isNotEmpty() && plan.criteriaIds.all { id -> unit.criteria.any { it.id == id } }) { "plan_criteria_invalid" }
        if (plan.source != "base") {
            require(plan.reason.isNotBlank() && plan.observe.isNotBlank() && plan.check.isNotBlank()) { "plan_fields_missing" }
            require(plan.hints.isNotEmpty() && plan.branches.isNotEmpty()) { "plan_paths_missing" }
        }
        listOf(plan.concepts, plan.hints, plan.branches).forEach { list ->
            require(list.size <= 8 && list.all { it.isNotBlank() && it.length <= 600 }) { "plan_list_invalid" }
        }
        require(plan.materials.size <= 8 && plan.materials.all { it.origin in ORIGINS && it.title.isNotBlank() && it.title.length <= 300 }) {
            "plan_material_invalid"
        }
        require(listOf(plan.reason, plan.observe, plan.check, plan.review).all { it.length <= 1200 } &&
            plan.coachNotes.length <= 4000 && plan.need.length <= 600) { "plan_text_too_long" }
        require(plan.basis.size <= 6) { "plan_basis_invalid" }
        plan.basis.forEach { basis ->
            val session = state.sessions.singleOrNull { it.id == basis.sessionId && it.course.id == plan.courseId }
                ?: error("plan_basis_unknown_lesson")
            val turn = session.turns.singleOrNull { it.id == basis.turnId && it.role == "user" && !it.sourceInvalidated }
                ?: error("plan_basis_unknown_turn")
            require(basis.quote.isNotBlank() && turn.text.contains(basis.quote)) { "plan_basis_quote_mismatch" }
        }
    }
}
