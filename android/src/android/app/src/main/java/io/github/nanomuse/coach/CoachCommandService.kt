package io.github.nanomuse.coach

import java.security.MessageDigest
import java.util.UUID
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

/** 教练页面与主聊天的唯一写入口，事务失败不会改变可观察状态。 */
class CoachCommandService(
    private val files: CoachFileStore,
    courses: List<CoachCourse>,
    legacyPaused: Set<String> = emptySet(),
    legacyNotes: Map<String, String> = emptyMap(),
    private val clock: () -> Long = System::currentTimeMillis,
) {
    private val json = Json { ignoreUnknownKeys = false; encodeDefaults = true }
    private val mutableState = MutableStateFlow(loadInitialState(courses, legacyPaused, legacyNotes))
    val state: StateFlow<CoachState> = mutableState
    @Volatile private var isValid = true

    /** 账户空间切换使旧界面引用失效，不能写入下一账户的文件。 */
    @Synchronized
    fun invalidate() { isValid = false; mutableState.value = CoachState() }

    /** 版本校验、幂等重放、完整落盘必须先于成功反馈。 */
    fun execute(command: CoachCommand, user: CoachUserInput? = null): CoachResult = execute(command, user, null)

    /** 专题入口在任何幂等重放和写入前先校验宿主范围。 */
    @Synchronized
    fun execute(command: CoachCommand, user: CoachUserInput? = null,
        scope: CoachConversationScope?): CoachResult {
        val current = mutableState.value
        return try {
            require(isValid) { "Coach space changed; reopen the current page" }
            CoachScopePolicy.validate(current, command, scope)
            validateCommand(command)
            val signature = signature(command)
            current.operations[command.operationId]?.let { previous ->
                require(previous.substringBefore('|') == signature) { "Operation ID already belongs to another command" }
                return CoachResult(true, "Already applied", current.revision, previous.substringAfter('|'))
            }
            require(command.expectedRevision == current.revision) { "State changed. Query the latest revision and retry." }
            validateCourseSnapshot(current, command)
            val (changed, target) = reduce(current, command, user)
            val committed = refreshProgress(changed).copy(schemaVersion = 3, revision = current.revision + 1,
                operations = current.operations + (command.operationId to "$signature|$target"))
            files.save(committed)
            mutableState.value = committed
            CoachResult(true, "Saved", committed.revision, target)
        } catch (error: Exception) {
            CoachResult(false, error.message ?: "Unable to save coach records", current.revision, command.targetId)
        }
    }

    /** 读取宿主绑定的专题，普通分组移动不构成授权。 */
    fun topicForConversation(chatSessionId: String): CoachTopic? = mutableState.value.topics
        .singleOrNull { chatSessionId.isNotBlank() && it.chatSessionId == chatSessionId }

    /** 只向宿主暴露绑定入口；模型命令没有此动作，也不能覆盖已有绑定。 */
    @Synchronized
    fun bindTopicConversation(topicId: String, chatSessionId: String): CoachResult = hostMutation {
        require(chatSessionId.isNotBlank()) { "A persisted conversation ID is required" }
        val topic = it.topic(topicId)
        require(topic.status == "active") { "Archived topics cannot bind or restore a conversation" }
        require(topic.chatSessionId.isBlank() || topic.chatSessionId == chatSessionId) { "Topic is already bound to another conversation" }
        require(it.topics.none { other -> other.id != topicId && other.chatSessionId == chatSessionId }) {
            "This conversation already belongs to another topic"
        }
        it.copy(topics = it.topics.map { value -> if (value.id == topicId) value.copy(chatSessionId = chatSessionId) else value },
            sessions = it.sessions.map { value -> if (value.topicId == topicId) value.copy(chatSessionId = chatSessionId) else value }) to topicId
    }

    /** 聊天被删除后专题只读归档，保留历史来源但不重建聊天或继承其证据。 */
    @Synchronized
    fun invalidateConversation(chatSessionId: String, reason: String): CoachResult = hostMutation { state ->
        val topic = state.topics.singleOrNull { it.chatSessionId == chatSessionId && chatSessionId.isNotBlank() }
            ?: error("Conversation is not bound to a topic")
        state.copy(topics = state.topics.map { if (it.id == topic.id)
            it.copy(status = "archived", activeSessionId = null, archiveReason = reason) else it },
            sessions = state.sessions.map { if (it.topicId == topic.id) it.copy(
                status = if (it.status == "complete") "complete" else "paused", pendingTurnId = null, assessment = null,
                turns = it.turns.map { turn -> turn.copy(sourceInvalidated = true) },
                evidence = it.evidence.map { item -> item.copy(disputed = true) },
                lessonSummary = it.lessonSummary?.copy(sourceInvalidated = true), revision = it.revision + 1) else it }) to topic.id
    }

    /** 编辑或删除原消息只撤销依赖它的证据，已保存原话保留供用户回看。 */
    @Synchronized
    fun invalidateMessage(chatSessionId: String, messageId: String, reason: String): CoachResult = hostMutation { state ->
        require(reason.isNotBlank()) { "Describe why the original message is unavailable" }
        val topic = state.topics.singleOrNull { it.chatSessionId == chatSessionId && chatSessionId.isNotBlank() }
            ?: error("Conversation is not bound to a topic")
        val sessions = state.sessions.map { session ->
            if (session.topicId != topic.id) session else invalidateSessionMessage(session, messageId)
        }
        state.copy(sessions = sessions) to topic.id
    }

    private fun invalidateSessionMessage(session: CoachSession, messageId: String): CoachSession {
        val originals = session.turns.filter { it.originMessageId == messageId }
        if (originals.isEmpty()) return session
        val assessmentIds = originals.filter { it.role == "coach" }.map { it.assessmentId }.filter(String::isNotBlank)
        val invalidIds = session.turns.filter { it.originMessageId == messageId || it.assessmentId in assessmentIds }.map { it.id }
        return session.copy(turns = session.turns.map { if (it.id in invalidIds) it.copy(sourceInvalidated = true) else it },
            evidence = session.evidence.map { if (it.turnId in invalidIds) it.copy(disputed = true) else it },
            pendingTurnId = session.pendingTurnId?.takeUnless { it in invalidIds },
            lessonSummary = session.lessonSummary?.let { summary ->
                if ((summary.sources + summary.corrections + summary.unresolvedHypotheses).any { it.turnId in invalidIds })
                    summary.copy(sourceInvalidated = true) else summary },
            assessment = session.assessment?.takeUnless { it.id in assessmentIds }, revision = session.revision + 1)
    }

    /** 宿主保存真实用户回合，结束后的普通追问仍留在上一课，不自动续课。 */
    @Synchronized
    fun registerConversationUser(chatSessionId: String, messageId: String, text: String,
        expectedSessionId: String? = null): CoachResult = hostMutation { current ->
        val topic = current.topics.singleOrNull { it.chatSessionId == chatSessionId && chatSessionId.isNotBlank() }
            ?: error("Conversation is not bound to a topic")
        val duplicate = current.sessions.find { session -> session.topicId == topic.id && session.turns.any {
            it.role == "user" && it.originMessageId == messageId } }
        if (duplicate != null) {
            val original = duplicate.turns.single { it.role == "user" && it.originMessageId == messageId }
            require(original.text == text && !original.sourceInvalidated) { "The original user message changed; invalidate its evidence first" }
            return@hostMutation current to duplicate.id
        }
        val latest = current.sessions.lastOrNull { it.topicId == topic.id }
        if (expectedSessionId != null) require(latest?.id == expectedSessionId) { "This message belongs to an earlier lesson" }
        val (started, id) = if (latest == null) CoachTopicCommands.startLesson(current, topic.id, clock()) else current to latest.id
        val session = started.session(id)
        validateCourseSnapshot(started, CoachCommand("lesson_message", "host", started.revision, id))
        val updated = CoachTeachingProtocol.message(session, text, CoachUserInput(messageId, text, chatSessionId), "question", clock())
            .copy(revision = session.revision + 1)
        started.copy(sessions = started.sessions.map { if (it.id == id) updated else it }) to id
    }

    /** 普通教学最终正文由宿主落盘；工具已保存的同一段正文只补上来源消息标识。 */
    @Synchronized
    fun recordConversationReply(chatSessionId: String, assistantId: String, text: String,
        expectedSessionId: String? = null): CoachResult = hostMutation { current ->
        require(assistantId.isNotBlank() && text.isNotBlank()) { "A final assistant message is required" }
        val topic = current.topics.singleOrNull { it.chatSessionId == chatSessionId && chatSessionId.isNotBlank() }
            ?: error("Conversation is not bound to a topic")
        val session = current.sessions.lastOrNull { it.topicId == topic.id } ?: error("Start a lesson first")
        if (expectedSessionId != null) require(session.id == expectedSessionId) { "This reply belongs to an earlier lesson" }
        val originals = session.turns.filter { it.role == "coach" && it.originMessageId == assistantId }
        if (originals.isNotEmpty()) {
            require(originals.any { it.text == text } && originals.none { it.sourceInvalidated }) {
                "The original reply changed; invalidate its evidence first"
            }
            return@hostMutation current to session.id
        }
        validateCourseSnapshot(current, CoachCommand("lesson_message", "host", current.revision, session.id))
        val last = session.turns.lastOrNull()
        val lastUserIndex = session.turns.indexOfLast { it.role == "user" }
        val sourcedTurns = session.turns.mapIndexed { index, turn ->
            if (index <= lastUserIndex || turn.role != "coach" || turn.originMessageId.isNotBlank()) turn
            else when {
                !turn.sourceInvalidated && text.contains(turn.text) -> turn.copy(originMessageId = assistantId)
                turn.purpose == "assessment" -> turn.copy(sourceInvalidated = true)
                else -> turn
            }
        }
        val turns = if (last?.role == "coach" && last.originMessageId.isBlank() &&
            !last.sourceInvalidated && last.text == text) {
            sourcedTurns
        } else sourcedTurns + CoachTurn(UUID.randomUUID().toString(), "coach", text, session.mode,
            support = session.nextSupport, originMessageId = assistantId, createdAt = clock(), purpose = "teaching")
        // 空编号不代表任何验证题；混入后会把所有普通回合一起作废（旧记录里可能已有这类回合）。
        val invalidAssessments = turns.filter { it.purpose == "assessment" && it.sourceInvalidated }
            .map { it.assessmentId }.filter(String::isNotBlank).toSet()
        val invalidTurns = turns.filter { it.assessmentId in invalidAssessments }.map { it.id }.toSet()
        val pending = session.turns.find { it.id == session.pendingTurnId }
        val updated = session.copy(turns = turns.map { if (it.id in invalidTurns) it.copy(sourceInvalidated = true) else it },
            assessment = session.assessment?.takeUnless { it.id in invalidAssessments },
            evidence = session.evidence.map { if (it.turnId in invalidTurns) it.copy(disputed = true) else it },
            pendingTurnId = session.pendingTurnId.takeIf {
            pending?.purpose == "attempt" || pending?.purpose == "report" }, stage = if (session.status == "complete") "complete" else session.mode,
            lessonSummary = session.lessonSummary?.let { summary -> summary.copy(
                sources = summary.sources.map { source -> source.copy(messageId = turns.find { it.id == source.turnId }?.originMessageId ?: source.messageId) },
                sourceInvalidated = summary.sourceInvalidated ||
                    (summary.sources + summary.corrections + summary.unresolvedHypotheses).any { it.turnId in invalidTurns }) },
            revision = session.revision + 1)
        current.copy(sessions = current.sessions.map { if (it.id == session.id) updated else it }) to session.id
    }

    /** 用户在宿主确认删除档案后清除本专题课次、来源摘录及现实任务，不提供模型工具入口。 */
    @Synchronized
    fun purgeConversation(chatSessionId: String): CoachResult = hostMutation(forgetPreviousSnapshot = true) { state ->
        val topic = state.topics.singleOrNull { it.chatSessionId == chatSessionId && chatSessionId.isNotBlank() }
            ?: error("Conversation is not bound to a topic")
        val sessionIds = state.sessions.filter { it.topicId == topic.id }.map { it.id }.toSet()
        val actionIds = state.actions.filter { it.sessionId in sessionIds }.map { it.id }.toSet()
        val deletedIds = sessionIds + actionIds + topic.id
        state.copy(topics = state.topics.filterNot { it.id == topic.id },
            sessions = state.sessions.filterNot { it.id in sessionIds }, actions = state.actions.filterNot { it.id in actionIds },
            operations = state.operations.filterValues { it.substringAfter('|') !in deletedIds },
            tracks = state.tracks.map { if (it.course.id == topic.courseId) it.copy(demonstrated = it.demonstrated - topic.unitId) else it }) to topic.id
    }

    private fun hostMutation(forgetPreviousSnapshot: Boolean = false,
        change: (CoachState) -> Pair<CoachState, String>): CoachResult {
        val current = mutableState.value
        return try {
            require(isValid) { "Coach space changed; reopen the current page" }
            val (updated, target) = change(current)
            if (updated == current) return CoachResult(true, "Already saved", current.revision, target)
            val committed = refreshProgress(updated).copy(schemaVersion = 3, revision = current.revision + 1)
            files.save(committed, forgetPreviousSnapshot)
            mutableState.value = committed
            CoachResult(true, "Saved", committed.revision, target)
        } catch (error: Exception) {
            CoachResult(false, error.message ?: "Unable to save topic records", current.revision)
        }
    }

    private fun refreshProgress(state: CoachState): CoachState {
        val tracks = state.tracks.map { track ->
            val related = state.topics.filter { it.courseId == track.course.id }
            val controlledUnits = related.map { it.unitId }.toSet()
            val achieved = related.filter { it.status == "active" && CoachTeachingProtocol.progress(state, it.id).isDemonstrated }
                .map { it.unitId }.toSet()
            // 专题存在后只依赖可追溯的新证据，删除来源必须能够撤销曾经显示的达成。
            track.copy(demonstrated = (track.demonstrated - controlledUnits) + achieved)
        }
        return state.copy(tracks = tracks)
    }

    /** 只升级仍与导入源一致的内置路径；历史会话原文、标准和证据一律保留。 */
    private fun loadInitialState(courses: List<CoachCourse>, legacyPaused: Set<String>, legacyNotes: Map<String, String>): CoachState {
        val saved = files.load() ?: return CoachState(tracks = courses.map {
            CoachTrack(it, paused = it.id in legacyPaused, legacyNote = legacyNotes[it.id].orEmpty())
        })
        val upgradedIds = mutableSetOf<String>()
        val tracks = saved.tracks.map { track ->
            val latest = courses.singleOrNull { it.id == track.course.id }
            val safeSource = latest != null && latest.source == track.course.source
            val shouldUpgrade = safeSource && latest!!.builtInSourceId == latest.id && latest.version != track.course.version
            val shouldBlock = safeSource && latest!!.needsCriteriaReview && !track.course.needsCriteriaReview
            val legacyImport = track.course.importProtocol.isBlank() && track.course.version.contains("local-")
                && !track.course.needsCriteriaReview
            if (!shouldUpgrade && !shouldBlock && !legacyImport) track
            else {
                upgradedIds += track.course.id
                val replacement = if (shouldUpgrade || shouldBlock) latest!! else track.course.copy(
                    needsCriteriaReview = true, units = track.course.units.map { it.copy(needsCriteriaReview = true) })
                track.copy(course = replacement, demonstrated = emptySet(),
                    legacyNote = (track.legacyNote + "\n课程证据标准已更新，旧会话保留供回看；继续训练前请审阅新标准并重新开始当前单元。").trim())
            }
        }
        if (upgradedIds.isEmpty()) return saved
        val sessions = saved.sessions.map { session ->
            if (session.course.id in upgradedIds) {
                session.copy(status = if (session.status == "complete") "complete" else "paused",
                    requiresCourseReview = true, revision = session.revision + 1)
            } else session
        }
        // 初始化升级同样先落盘；失败时不以仅存内存的新标准继续训练。
        val upgraded = saved.copy(tracks = tracks, sessions = sessions, revision = saved.revision + 1)
        files.save(upgraded)
        return upgraded
    }

    private fun validateCourseSnapshot(state: CoachState, command: CoachCommand) {
        val sessionId = when (command.action) {
            "answer", "lesson_message", "end_lesson", "coach_reply", "resume_session", "request_hint", "dispute", "action_plan",
            "save_input", "pause_session" -> command.targetId
            "action_update", "action_defer", "action_resume", "action_report" -> state.actions.singleOrNull {
                it.id == command.targetId
            }?.sessionId
            else -> null
        } ?: return
        val session = state.session(sessionId)
        if (session.topicId.isNotBlank()) require(state.topic(session.topicId).status == "active") {
            "This topic is archived; its lesson records are read-only"
        }
        require(!session.requiresCourseReview) { "课程标准已更新；旧会话已保留，请在课程页审阅新标准后重新开始当前单元。" }
        require(session.course.version == state.track(session.course.id).course.version) {
            "该会话使用旧版课程标准，只保留供回看，请重新开始当前课程。"
        }
        require(!session.course.needsCriteriaReview && session.course.units.none { it.needsCriteriaReview }) {
            "课程标准尚待审阅，请通过新版草案审阅并确认后再训练。"
        }
    }

    private fun validateCommand(command: CoachCommand) {
        require(command.operationId.length in 1..160) { "A stable operationId is required" }
        require(command.text.length <= 40_000 && command.payload.length <= 200_000) { "Content is too long" }
    }

    private fun signature(command: CoachCommand): String {
        val content = json.encodeToString(command.copy(expectedRevision = 0))
        return MessageDigest.getInstance("SHA-256").digest(content.toByteArray())
            .joinToString("") { "%02x".format(it) }
    }

    private fun reduce(state: CoachState, command: CoachCommand, user: CoachUserInput?): Pair<CoachState, String> =
        when (command.action) {
            "start_topic", "start_lesson", "end_lesson" -> CoachTopicCommands.apply(state, command, clock())
            "start" -> start(state, command.targetId)
            "pause_course", "resume_course", "advance" -> changeCourse(state, command)
            "save_input", "answer", "lesson_message", "coach_reply", "pause_session", "resume_session", "request_hint", "dispute" ->
                changeSession(state, command, user)
            "new_draft", "revise_draft", "propose", "activate" -> CoachDraftCommands.apply(state, command, user)
            "action_plan", "action_update", "action_defer", "action_resume", "action_report" ->
                if (command.action == "action_report") reportTopicAction(state, command, user)
                else CoachActionCommands.apply(state, command, user)
            else -> error("Unsupported coach action")
        }

    private fun reportTopicAction(state: CoachState, command: CoachCommand, user: CoachUserInput?): Pair<CoachState, String> {
        val action = state.actions.singleOrNull { it.id == command.targetId } ?: error("Action task not found")
        val session = state.session(action.sessionId)
        if (session.teachingProtocol != CoachTeachingProtocol.VERSION) return CoachActionCommands.apply(state, command, user)
        requireUserQuote(command.text, user)
        if (action.reports.any { it.originMessageId == user!!.messageId }) return state to action.id
        val saved = session.turns.find { it.role == "user" && it.originMessageId == user!!.messageId }
        require(session.pendingTurnId == null || session.pendingTurnId == saved?.id) { "Wait for the current reply first" }
        val report = (saved ?: CoachTurn(UUID.randomUUID().toString(), "user", command.text, "real_report",
            originMessageId = user!!.messageId, createdAt = clock())).copy(stage = "real_report", context = "reported_real",
            purpose = "report", dimension = "application", assessmentId = "", reviewKind = "immediate", reviewOfSessionId = "")
        val updated = session.copy(turns = if (saved == null) session.turns + report else session.turns.map {
            if (it.id == saved.id) report else it }, pendingTurnId = report.id, status = "active", stage = "real_report",
            revision = session.revision + 1)
        return state.copy(sessions = state.sessions.map { if (it.id == session.id) updated else it },
            actions = state.actions.map { if (it.id == action.id) it.copy(status = "reported", reports = it.reports + report) else it }) to action.id
    }

    private fun start(state: CoachState, courseId: String): Pair<CoachState, String> {
        val track = state.track(courseId)
        require(!track.paused) { "Resume this course before starting" }
        require(!track.course.needsCriteriaReview && track.course.units.none { it.needsCriteriaReview }) {
            "课程的原理、情景、实践或现实证据要求尚未明确，请通过新版草案审阅并确认后再训练。"
        }
        require(track.course.units.any { it.id == track.currentUnitId }) { "Course units need review before training" }
        val existing = state.sessions.lastOrNull { it.course.id == courseId &&
            it.course.version == track.course.version && !it.requiresCourseReview &&
            it.status in setOf("active", "paused", "waiting_real") }
        if (existing != null) return state to existing.id
        val session = CoachSession(UUID.randomUUID().toString(), track.course, track.currentUnitId)
        return state.copy(sessions = state.sessions + session, selectedCourseId = courseId,
            tracks = state.tracks.map { if (it.course.id == courseId) it.copy(lastPracticedAt = System.currentTimeMillis()) else it }) to session.id
    }

    private fun changeCourse(state: CoachState, command: CoachCommand): Pair<CoachState, String> {
        val track = state.track(command.targetId)
        val updated = when (command.action) {
            "pause_course" -> track.copy(paused = true)
            "resume_course" -> track.copy(paused = false)
            else -> {
                require(track.currentUnitId in track.demonstrated) { "This unit still needs evidence" }
                val index = track.course.units.indexOfFirst { it.id == track.currentUnitId }
                require(index >= 0 && index + 1 < track.course.units.size) { "No next unit is available" }
                track.copy(currentUnitId = track.course.units[index + 1].id)
            }
        }
        val sessions = if (command.action == "pause_course") state.sessions.map {
            if (it.course.id == track.course.id && it.status == "active") it.copy(status = "paused", revision = it.revision + 1) else it
        } else state.sessions
        return state.copy(tracks = state.tracks.map { if (it.course.id == track.course.id) updated else it },
            sessions = sessions) to track.course.id
    }

    private fun changeSession(state: CoachState, command: CoachCommand, user: CoachUserInput?): Pair<CoachState, String> {
        val session = state.session(command.targetId)
        val updated = when (command.action) {
            "save_input" -> session.copy(draft = command.text)
            "pause_session" -> session.copy(status = "paused", draft = command.text.ifBlank { session.draft })
            "resume_session" -> {
                require(!state.track(session.course.id).paused) { "Resume this course first" }
                require(session.status == "paused") { "Only a paused session can resume" }
                session.copy(status = "active")
            }
            "request_hint" -> requestHint(session)
            "answer", "lesson_message" -> if (session.teachingProtocol == CoachTeachingProtocol.VERSION) {
                require(user != null) { "A real user message is required" }
                val purpose = if (command.action == "answer") "attempt" else
                    org.json.JSONObject(command.payload.ifBlank { "{}" }).let { // JSON null 按默认用途处理，不读成 "null"
                        if (it.isNull("purpose")) "question" else it.optString("purpose", "question") }
                CoachTeachingProtocol.message(session, command.text, user, purpose, clock())
            } else answer(session, command.text, user)
            "coach_reply" -> if (session.teachingProtocol == CoachTeachingProtocol.VERSION)
                CoachTeachingProtocol.reply(state, session, command.text, command.payload, clock())
                else CoachTrainingEngine.reply(session, command.text, command.payload)
            "dispute" -> {
                require(state.sessions.none { it.id != session.id && it.course.id == session.course.id &&
                    it.course.version == session.course.version && !it.requiresCourseReview &&
                    it.status in setOf("active", "paused", "waiting_real") }) {
                    "Finish or pause reassessment until the current session has ended"
                }
                require(command.text.isNotBlank()) { "Explain what the assessment missed" }
                val comment = CoachTurn(UUID.randomUUID().toString(), "user", command.text, "dispute", support = "hinted",
                    originMessageId = user?.messageId.orEmpty())
                session.copy(evidence = session.evidence.map { it.copy(disputed = true) },
                    turns = session.turns + comment, status = "active",
                    stage = if (session.teachingProtocol == CoachTeachingProtocol.VERSION) "question" else "retry",
                    nextSupport = "hinted", pendingTurnId = null, assessment = null)
            }
            else -> error("Unsupported session action")
        }.copy(revision = session.revision + 1)
        val demonstrated = CoachTrainingEngine.demonstrated(updated)
        val tracks = state.tracks.map { track ->
            if (track.course.id != session.course.id) track
            else track.copy(demonstrated = when {
                command.action == "dispute" -> track.demonstrated - session.unitId
                demonstrated && track.course.version == session.course.version -> track.demonstrated + session.unitId
                else -> track.demonstrated
            })
        }
        return state.copy(sessions = state.sessions.map { if (it.id == session.id) updated else it }, tracks = tracks) to session.id
    }

    private fun requestHint(session: CoachSession): CoachSession {
        if (session.teachingProtocol == CoachTeachingProtocol.VERSION) {
            require(session.status == "active") { "Resume the lesson first" }
            return session.copy(nextSupport = "hinted", turns = session.turns.map {
                if (it.id == session.pendingTurnId) it.copy(support = "hinted") else it
            })
        }
        require(session.status == "active" && session.pendingTurnId == null) { "Wait for the current reply first" }
        require(session.stage in setOf("first", "retry", "probe")) { "Start a scene first" }
        return session.copy(stage = "retry", nextSupport = "hinted")
    }

    private fun answer(session: CoachSession, text: String, user: CoachUserInput?): CoachSession {
        require(session.status == "active" && session.pendingTurnId == null) { "A reply is pending or this session is paused" }
        require(session.stage in setOf("first", "retry", "probe")) { "Ask the next scene before answering" }
        requireUserQuote(text, user)
        if (session.turns.any { it.originMessageId == user!!.messageId && it.role == "user" }) return session
        val turn = CoachTurn(UUID.randomUUID().toString(), "user", text, session.stage,
            support = session.nextSupport, originMessageId = user!!.messageId)
        return session.copy(turns = session.turns + turn, pendingTurnId = turn.id, draft = "",
            chatSessionId = user.chatSessionId)
    }
}

/** 查找精确ID，歧义交给对话澄清，不能默改最近对象。 */
internal fun CoachState.track(id: String): CoachTrack = tracks.singleOrNull { it.course.id == id }
    ?: error("Course not found; query and select an exact course ID")

/** 会话引用失效时不新建替代会话。 */
internal fun CoachState.session(id: String): CoachSession = sessions.singleOrNull { it.id == id }
    ?: error("Session not found; query and select an exact session ID")

/** 训练与现实报告只接受本轮实际用户消息中的连续原文。 */
internal fun requireUserQuote(text: String, user: CoachUserInput?) {
    require(user != null && user.messageId.isNotBlank() && text.isNotBlank() && user.text.contains(text)) {
        "Answer/report must quote the current user message verbatim"
    }
}
