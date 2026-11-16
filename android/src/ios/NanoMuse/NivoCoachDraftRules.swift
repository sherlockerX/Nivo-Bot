import Foundation

/// 目标探索、提案和后续确认分开保存，改动目标会立即作废旧提案。
enum NivoCoachDraftRules {
    /// 新课程和改版课程都走同一条可审阅事务，讨论本身不会激活课程。
    static func apply(_ command: NivoCoachCommand, payload: NivoCoachPayload, context: NivoCoachCommandContext,
                      state: inout NivoCoachState, now: Int64) throws -> NivoCoachApplied {
        if command.action == "new_draft" {
            try requireText(command.text, context: context)
            let draft = NivoCoachDraft(id: UUID().uuidString, text: command.text)
            state.drafts.append(draft)
            return try NivoCoachApplied(id: draft.id, value: draft)
        }
        guard let index = state.drafts.firstIndex(where: { $0.id == command.targetID }) else { throw NivoLifeError.notFound("coach_draft") }
        var draft = state.drafts[index]
        guard draft.status != "activated" else { throw NivoLifeError.invalidTransition("activated_draft") }
        switch command.action {
        case "revise_draft":
            try requireText(command.text, context: context)
            draft.text = command.text
            draft.course = nil
            draft.status = "needs_review"
            draft.sourceStatus = "unverified"
            draft.proposedFromMessageID = ""
            draft.proposedAt = nil
        case "propose": draft = try proposed(draft, payload: payload, context: context, state: state, now: now)
        case "activate":
            let track = try activate(draft, payload: payload, command: command, context: context, state: &state)
            draft.status = "activated"
            draft.activatedCourseID = track.id
            draft.revision = try NivoCoachReducer.increment(draft.revision)
            state.drafts[index] = draft
            return try NivoCoachApplied(id: track.id, value: track)
        default: throw NivoLifeError.invalidField("coach_action")
        }
        draft.revision = try NivoCoachReducer.increment(draft.revision)
        state.drafts[index] = draft
        return try NivoCoachApplied(id: draft.id, value: draft)
    }

    private static func requireText(_ text: String, context: NivoCoachCommandContext) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf16.count <= 12_000 else { throw NivoLifeError.invalidField("draft") }
        if !context.isHost { _ = try NivoCoachPolicy.quote(text, user: context.user) }
    }

    private static func proposed(_ original: NivoCoachDraft, payload: NivoCoachPayload, context: NivoCoachCommandContext,
                                 state: NivoCoachState, now: Int64) throws -> NivoCoachDraft {
        guard var course = payload.course, let sourceStatus = payload.sourceStatus,
              ["self_authored", "verified", "unverified"].contains(sourceStatus) else { throw NivoLifeError.invalidField("course_proposal") }
        try validate(course)
        let nextRevision = try NivoCoachReducer.increment(original.revision)
        if !state.tracks.contains(where: { $0.id == course.id }) { course.id = "course-" + original.id }
        course.version = original.id + ":" + String(nextRevision)
        var draft = original
        draft.course = course
        draft.status = "proposed"
        draft.sourceStatus = sourceStatus
        draft.proposedFromMessageID = context.user?.id ?? ""
        draft.proposedAt = now
        return draft
    }

    private static func activate(_ draft: NivoCoachDraft, payload: NivoCoachPayload, command: NivoCoachCommand,
                                 context: NivoCoachCommandContext, state: inout NivoCoachState) throws -> NivoCoachTrack {
        guard let expected = payload.draftRevision else { throw NivoLifeError.invalidField("draftRevision") }
        try NivoTodoRules.requireRevision(expected, actual: draft.revision)
        guard ["proposed", "review"].contains(draft.status), draft.sourceStatus != "unverified",
              let course = draft.course else { throw NivoLifeError.invalidField("course_review") }
        try validate(course)
        try requireConfirmation(draft, command: command, context: context, state: state)
        var track = state.tracks.first { $0.id == course.id } ?? NivoCoachTrack(course: course, currentUnitID: course.units[0].id)
        track.course = course
        if !course.units.contains(where: { $0.id == track.currentUnitID }) { track.currentUnitID = course.units[0].id }
        track.demonstrated = []
        if let index = state.tracks.firstIndex(where: { $0.id == course.id }) { state.tracks[index] = track }
        else { state.tracks.append(track) }
        for index in state.sessions.indices where state.sessions[index].course.id == course.id && state.sessions[index].course.version != course.version {
            if state.sessions[index].status != "complete" { state.sessions[index].status = "paused" }
            state.sessions[index].requiresCourseReview = true
            state.sessions[index].revision = try NivoCoachReducer.increment(state.sessions[index].revision)
        }
        state.selectedCourseID = course.id
        return track
    }

    private static func requireConfirmation(_ draft: NivoCoachDraft, command: NivoCoachCommand,
                                            context: NivoCoachCommandContext, state: NivoCoachState) throws {
        if context.isHost {
            guard NivoCoachPolicy.confirms(command.text) else { throw NivoLifeError.invalidField("confirmation") }
            return
        }
        guard let user = context.user, user.id != draft.proposedFromMessageID,
              draft.proposedAt.map({ user.createdAt > $0 }) ?? true, NivoCoachPolicy.confirms(user.text) else {
            throw NivoLifeError.invalidField("later_confirmation")
        }
        if !command.text.isEmpty { _ = try NivoCoachPolicy.quote(command.text, user: user) }
        let waiting = state.drafts.filter { ["proposed", "review"].contains($0.status) }
        guard waiting.count == 1 || user.text.contains(draft.id) || user.text.contains(draft.course?.title ?? draft.id) else {
            throw NivoLifeError.invalidField("ambiguous_confirmation")
        }
    }

    /// 对新提案要求明确来源、互不重复的标准和双维度目标。
    static func validate(_ course: NivoCoachCourse) throws {
        try NivoCoachPolicy.requireReviewed(course)
        guard !course.id.isEmpty, !course.title.isEmpty, !course.place.isEmpty, !course.source.isEmpty,
              !course.version.isEmpty, (1...60).contains(course.units.count),
              Set(course.units.map(\.id)).count == course.units.count else { throw NivoLifeError.invalidField("course") }
        for unit in course.units { try validateUnit(unit) }
    }

    private static func validateUnit(_ unit: NivoCoachUnit) throws {
        guard !unit.id.isEmpty, !unit.title.isEmpty, !unit.focus.isEmpty, !unit.method.isEmpty, !unit.source.isEmpty,
              !unit.criteria.isEmpty, Set(unit.criteria.map(\.id)).count == unit.criteria.count,
              unit.criteria.allSatisfy({ !$0.id.isEmpty && !$0.description.isEmpty }) else { throw NivoLifeError.invalidField("course_unit") }
        let dimensions = Set(unit.criteria.map { NivoCoachPolicy.dimension($0) })
        guard dimensions == Set(NivoCoachTeaching.dimensions),
              !unit.criteria.contains(where: { $0.requiresRealAction && NivoCoachPolicy.dimension($0) != "application" }) else {
            throw NivoLifeError.invalidField("course_dimensions")
        }
    }
}
