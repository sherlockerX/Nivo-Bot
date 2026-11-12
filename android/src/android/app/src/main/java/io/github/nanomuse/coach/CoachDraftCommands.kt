package io.github.nanomuse.coach

import java.util.UUID
import kotlinx.serialization.json.Json
import org.json.JSONObject

/** 课程先探索、后审阅，确认精确版本后才进入能力地图。 */
internal object CoachDraftCommands {
    private val json = Json { ignoreUnknownKeys = false }

    fun apply(state: CoachState, command: CoachCommand, user: CoachUserInput?): Pair<CoachState, String> {
        if (command.action == "new_draft") {
            require(command.text.isNotBlank()) { "Describe an event or exploration request first" }
            if (user != null) requireUserQuote(command.text, user)
            val draft = CoachDraft(UUID.randomUUID().toString(), command.text)
            return state.copy(drafts = state.drafts + draft) to draft.id
        }
        val draft = state.drafts.singleOrNull { it.id == command.targetId } ?: error("Draft not found")
        require(draft.status != "activated") { "Create a new draft to revise an active course" }
        return when (command.action) {
            "revise_draft" -> {
                require(command.text.isNotBlank()) { "Describe the requested change" }
                replace(state, draft.copy(text = command.text, course = null,
                    revision = draft.revision + 1, status = "needs_review", sourceStatus = "unverified"))
            }
            "propose" -> propose(state, draft, command.payload, user)
            "activate" -> activate(state, draft, command.payload, user)
            else -> error("Unknown draft action")
        }
    }

    private fun propose(state: CoachState, draft: CoachDraft, payload: String, user: CoachUserInput?): Pair<CoachState, String> {
        val data = JSONObject(payload)
        val course = json.decodeFromString<CoachCourse>(data.getJSONObject("course").toString())
        validate(course)
        val sourceStatus = data.getString("sourceStatus")
        require(sourceStatus in setOf("self_authored", "verified", "unverified")) { "Unknown source status" }
        // 来源声明保留供用户审阅，无法核实的教学资料不能直接激活。
        val proposal = course.copy(id = if (state.tracks.any { it.course.id == course.id }) course.id else "course-${draft.id}",
            version = "${draft.id}:${draft.revision + 1}")
        return replace(state, draft.copy(course = proposal, revision = draft.revision + 1,
            status = "review", sourceStatus = sourceStatus, proposedFromMessageId = user?.messageId.orEmpty()))
    }

    private fun activate(state: CoachState, draft: CoachDraft, payload: String, user: CoachUserInput?): Pair<CoachState, String> {
        val data = JSONObject(payload)
        require(data.getLong("draftRevision") == draft.revision) { "The reviewed proposal is stale" }
        require(draft.status == "review" && draft.sourceStatus != "unverified") { "Review sources and the revised proposal before activation" }
        require(user == null || (user.messageId != draft.proposedFromMessageId && confirms(user.text))) {
            "Wait for the user to confirm this specific proposal in a later message"
        }
        val course = draft.course ?: error("This draft has no reviewed course")
        require(user == null || state.drafts.count { it.status == "review" } == 1 ||
            user.text.contains(course.title) || user.text.contains(draft.id)) {
            "Several proposals are awaiting review; ask which course the user confirms"
        }
        validate(course)
        val existing = state.tracks.find { it.course.id == course.id }
        val track = existing?.copy(course = course,
            currentUnitId = existing.currentUnitId.takeIf { id -> course.units.any { it.id == id } }
                ?: course.units.first().id,
            // 改版后保留旧会话证据，但新标准必须重新展示。
            demonstrated = emptySet()) ?: CoachTrack(course)
        val tracks = if (existing == null) state.tracks + track else state.tracks.map {
            if (it.course.id == course.id) track else it
        }
        val sessions = if (existing == null) state.sessions else state.sessions.map { session ->
            if (session.course.id == course.id && session.course.version != course.version) {
                session.copy(status = if (session.status == "complete") "complete" else "paused",
                    requiresCourseReview = true, revision = session.revision + 1)
            } else session
        }
        return state.copy(tracks = tracks, sessions = sessions, selectedCourseId = course.id,
            drafts = state.drafts.map { if (it.id == draft.id) draft.copy(status = "activated", activatedCourseId = course.id) else it }) to course.id
    }

    /** 明确同意才允许聊天激活，负面和继续修改的语句不构成同意。 */
    internal fun confirms(text: String): Boolean {
        if (Regex("不要|取消|不创建|不加入|不确认|先别|暂不|修改|改一下|don't|do not|cancel", RegexOption.IGNORE_CASE).containsMatchIn(text)) return false
        return Regex("确认|就按|按这|加入|创建|可以开始|同意|confirm|create|activate|go ahead", RegexOption.IGNORE_CASE).containsMatchIn(text)
    }

    private fun validate(course: CoachCourse) {
        require(!course.needsCriteriaReview && course.units.none { it.needsCriteriaReview }) {
            "课程标准尚待审阅，请明确各单元要求并提交可审阅的新版提案。"
        }
        require(course.title.isNotBlank() && course.place.isNotBlank() && course.source.isNotBlank()) { "Course title, place and sources/limitations are required" }
        require(course.units.size in 1..60) { "A reviewed course needs 1 to 60 ordered units" }
        require(course.units.map { it.id }.distinct().size == course.units.size) { "Unit IDs must be unique" }
        course.units.forEach { unit ->
            require(unit.id.isNotBlank() && unit.title.isNotBlank() && unit.focus.isNotBlank() && unit.method.isNotBlank()) { "Each unit needs a goal and method" }
            require(unit.criteria.isNotEmpty() && unit.criteria.all { it.id.isNotBlank() && it.description.isNotBlank() }) { "Each unit needs explicit completion evidence" }
            require(unit.criteria.map { it.id }.distinct().size == unit.criteria.size) { "Criterion IDs must be unique within a unit" }
            if (unit.criteria.any { it.dimension.isNotBlank() }) {
                require(unit.criteria.all { it.dimension in CoachTeachingProtocol.DIMENSIONS }) { "Each criterion needs a known evidence dimension" }
                require(unit.criteria.map { it.dimension }.toSet() == CoachTeachingProtocol.DIMENSIONS) {
                    "Each new unit requires both understanding and application evidence"
                }
                require(unit.criteria.none { it.requiresRealAction && it.dimension != "application" }) {
                    "A real-action requirement belongs to application evidence"
                }
            }
            require(unit.source.isNotBlank()) { "Each unit needs a source or a self-authored exercise statement" }
        }
    }

    private fun replace(state: CoachState, draft: CoachDraft): Pair<CoachState, String> =
        state.copy(drafts = state.drafts.map { if (it.id == draft.id) draft else it }) to draft.id
}
