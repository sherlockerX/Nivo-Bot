package io.github.nanomuse.coach

import java.time.ZoneId
import java.util.UUID
import kotlinx.serialization.json.Json
import org.json.JSONObject

/** 专题和课次分开建档，课程版本变化不重写旧课次。 */
internal object CoachTopicCommands {
    /** 执行不依赖聊天宿主的专题生命周期命令。 */
    fun apply(state: CoachState, command: CoachCommand, now: Long, zone: ZoneId = ZoneId.systemDefault()): Pair<CoachState, String> =
        when (command.action) {
            "start_topic" -> startTopic(state, command, now)
            "start_lesson" -> startLesson(state, command.targetId, now, zone)
            "end_lesson" -> endLesson(state, command, now)
            "retarget_topic" -> retargetTopic(state, command.targetId)
            "seal_lesson" -> sealLesson(state, command.targetId, now)
            "adopt_plan" -> adoptPlan(state, command)
            else -> error("Unknown topic action")
        }

    private val planJson = Json { ignoreUnknownKeys = false; encodeDefaults = true }

    /** 技能的长期专题跟随当前单元；已开始的课节保留原单元，换单元不换聊天。 */
    private fun retargetTopic(state: CoachState, topicId: String): Pair<CoachState, String> {
        val topic = state.topic(topicId)
        val track = state.track(topic.courseId)
        validateTrack(track)
        require(topic.status == "active") { "This topic is not active" }
        if (topic.unitId == track.currentUnitId) return state to topic.id
        val open = topic.activeSessionId?.let { id -> state.sessions.find { it.id == id } }
        require(open == null || open.status !in CoachSkillProfile.OPEN_STATUSES) { "Finish or set aside the open lesson first" }
        val unit = track.course.units.singleOrNull { it.id == track.currentUnitId } ?: error("Unit not found")
        return state.copy(topics = state.topics.map {
            if (it.id == topic.id) it.copy(unitId = unit.id, caseText = unit.focus, activeSessionId = null) else it
        }) to topic.id
    }

    /** 「开始今天」封存昨天未完的课节：草稿与待反馈回答保留可查，现实行动继续等待。 */
    private fun sealLesson(state: CoachState, sessionId: String, now: Long): Pair<CoachState, String> {
        val session = state.session(sessionId)
        require(session.teachingProtocol == CoachTeachingProtocol.VERSION) { "Choose a topic lesson" }
        if (session.status == "sealed" || session.status == "complete") return state to session.id
        require(session.status in CoachSkillProfile.OPEN_STATUSES) { "Only an open lesson can be set aside" }
        val updated = if (session.status == "waiting_real") session.copy(sealedAt = now, revision = session.revision + 1)
            else session.copy(status = "sealed", sealedAt = now, revision = session.revision + 1)
        return state.copy(sessions = state.sessions.map { if (it.id == session.id) updated else it },
            topics = state.topics.map { if (it.id == session.topicId)
                it.copy(activeSessionId = it.activeSessionId.takeUnless { id -> id == session.id }) else it }) to session.id
    }

    /** 宿主校验后采用教案；同日较新的教案不会被迟到的旧结果覆盖。 */
    private fun adoptPlan(state: CoachState, command: CoachCommand): Pair<CoachState, String> {
        val plan = planJson.decodeFromString(CoachLessonPlan.serializer(), command.payload).copy(status = "adopted")
        require(plan.courseId == command.targetId) { "The plan belongs to another skill" }
        if (state.plans.any { it.id == plan.id }) return state to plan.id
        CoachLessonPlanRules.validate(state, plan)
        require(state.plans.none { it.courseId == plan.courseId && it.localDate == plan.localDate &&
            it.status == "adopted" && it.createdAt > plan.createdAt }) { "stale_plan_result" }
        val plans = state.plans.map {
            if (it.courseId == plan.courseId && it.localDate == plan.localDate && it.status == "adopted") it.copy(status = "superseded") else it
        } + plan
        return state.copy(plans = plans.takeLast(MAX_PLANS)) to plan.id
    }

    private const val MAX_PLANS = 90

    private fun startTopic(state: CoachState, command: CoachCommand, now: Long): Pair<CoachState, String> {
        val track = state.track(command.targetId)
        validateTrack(track)
        val data = if (command.payload.isBlank()) JSONObject() else JSONObject(command.payload)
        // Android 的 optString 会把 JSON null 读成字符串 "null"；null 按未提供处理，免得找不到单元或标题显示成 null。
        val unitId = if (data.isNull("unitId")) track.currentUnitId else data.optString("unitId", track.currentUnitId)
        val unit = track.course.units.singleOrNull { it.id == unitId } ?: error("Unit not found")
        val caseText = command.text.trim().ifBlank { unit.focus }
        val title = (if (data.isNull("title")) "" else data.optString("title")).trim().ifBlank { unit.title }
        require(title.length <= 160 && caseText.length <= 16_000) { "Topic content is too long" }
        val existing = state.topics.lastOrNull { it.courseId == track.course.id && it.unitId == unitId &&
            it.caseText == caseText && it.status == "active" }
        if (existing != null) return state to existing.id
        val topic = CoachTopic(UUID.randomUUID().toString(), track.course.id, unitId, title, caseText, createdAt = now)
        return state.copy(topics = state.topics + topic, selectedCourseId = track.course.id) to topic.id
    }

    /** 同一专题只保留一节正在进行的课，重试不创建平行课次。 */
    fun startLesson(state: CoachState, topicId: String, now: Long, zone: ZoneId = ZoneId.systemDefault()): Pair<CoachState, String> {
        val topic = state.topic(topicId)
        val track = state.track(topic.courseId)
        validateTrack(track)
        require(topic.status == "active") { "This topic is not active" }
        val current = topic.activeSessionId?.let { id -> state.sessions.find { it.id == id } }
        if (current != null && !current.requiresCourseReview && current.course.version == track.course.version &&
            current.status in setOf("active", "paused", "waiting_real")) return state to current.id
        require(track.course.units.any { it.id == topic.unitId }) { "Review the changed topic unit before continuing" }
        val today = CoachDay.key(now, zone)
        // 今天已采用的教案绑定到新课节；之后改教案不影响这节课。
        val plan = state.plans.lastOrNull { it.courseId == track.course.id && it.localDate == today &&
            it.status == "adopted" && it.unitId == topic.unitId && it.courseVersion == track.course.version }
        val session = CoachSession(UUID.randomUUID().toString(), track.course, topic.unitId,
            topicId = topic.id, teachingProtocol = CoachTeachingProtocol.VERSION,
            chatSessionId = topic.chatSessionId, startedAt = now, localDate = today, zoneId = zone.id,
            planId = plan?.id.orEmpty())
        return state.copy(sessions = state.sessions + session, topics = state.topics.map {
            if (it.id == topic.id) it.copy(activeSessionId = session.id) else it
        }, tracks = state.tracks.map { if (it.course.id == track.course.id) it.copy(lastPracticedAt = now) else it }) to session.id
    }

    private fun endLesson(state: CoachState, command: CoachCommand, now: Long): Pair<CoachState, String> {
        val session = state.session(command.targetId)
        require(session.teachingProtocol == CoachTeachingProtocol.VERSION) { "Choose a topic lesson" }
        // 已结束的课再次结束（连点或旧课次ID）原样返回：不改写摘要和结束时间（延时复习按它计时），也不清掉专题指向的新课。
        if (session.status == "complete") return state to session.id
        val pending = session.turns.find { it.id == session.pendingTurnId }
        require(pending?.purpose !in setOf("attempt", "report")) { "Save feedback on the pending attempt before ending this lesson" }
        val summary = command.text.ifBlank { session.summary }
        val data = JSONObject(command.payload.ifBlank { "{}" })
        val sources = session.turns.filter { !it.sourceInvalidated }.takeLast(24).map {
            // 截断不能停在表情等代理对中间：单个代理写成 UTF-8 会变成 "?"，落盘校验失败，这一课就再也结束不了。
            CoachSummarySource(it.id, it.originMessageId, it.text.take(600).let { cut ->
                if (cut.isNotEmpty() && cut.last().isHighSurrogate()) cut.dropLast(1) else cut }) }
        val structured = CoachLessonSummary(summary, session.course.version, session.revision, sources,
            quotedSources(session, data, "corrections"), quotedSources(session, data, "unresolvedHypotheses"))
        val updated = session.copy(status = "complete", stage = "complete", summary = summary, lessonSummary = structured,
            assessment = null, pendingTurnId = null, endedAt = now, revision = session.revision + 1)
        return state.copy(sessions = state.sessions.map { if (it.id == session.id) updated else it },
            topics = state.topics.map { if (it.id == session.topicId)
                it.copy(activeSessionId = it.activeSessionId.takeUnless { id -> id == session.id }) else it }) to session.id
    }

    private fun quotedSources(session: CoachSession, data: JSONObject, name: String): List<CoachSummarySource> {
        val entries = data.optJSONArray(name) ?: return emptyList()
        require(entries.length() <= 12) { "Too many summary references" }
        return (0 until entries.length()).map { index ->
            val entry = entries.getJSONObject(index)
            val turn = session.turns.singleOrNull { it.id == entry.getString("turnId") && !it.sourceInvalidated }
                ?: error("Summary must reference a saved original turn")
            val quote = entry.getString("quote")
            require(quote.isNotBlank() && turn.text.contains(quote)) { "Summary reference must quote the original turn" }
            CoachSummarySource(turn.id, turn.originMessageId, quote)
        }
    }

    private fun validateTrack(track: CoachTrack) {
        require(!track.paused) { "Resume this course first" }
        require(!track.course.needsCriteriaReview && track.course.units.none { it.needsCriteriaReview }) {
            "Review explicit course criteria before teaching"
        }
    }
}

/** 精确专题引用失效时拒绝，不能悄悄切到另一个案例。 */
internal fun CoachState.topic(id: String): CoachTopic = topics.singleOrNull { it.id == id }
    ?: error("Topic not found; query and select an exact topic ID")
