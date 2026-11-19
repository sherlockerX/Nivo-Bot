import XCTest
@testable import Minis

/// 对照可见消息来源验证topic-v3，不把模型工具中的隐藏内容视为已完成教学。
final class NivoCoachTeachingTests: XCTestCase {
    func testStartingLessonRecordsItsLocalDate() throws {
        var state = state()
        state.topics[0].activeSessionID = nil
        let now: Int64 = 1_700_000_000_000
        let lesson = try NivoCoachReducer.startLesson(topicID: "topic", state: &state, now: now)
        let encoded = try JSONEncoder().encode(lesson)
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNotNil(fields["localDate"] as? String)
        XCTAssertEqual(fields["zoneId"] as? String, TimeZone.current.identifier)
    }

    func testStartingTodaySetsAsideEarlierLessonAndKeepsItsPlan() throws {
        var state = state()
        let now: Int64 = 1_700_000_000_000
        let zone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        state.sessions[0].localDate = "2023-11-13"
        state.sessions[0].draft = "Draft for the earlier lesson"
        state.sessions[0].planID = "earlier-plan"
        state.plans = [try NivoCoachLessonPlanRules.base(state, courseID: "course", now: now, zone: zone,
            minutes: 15, need: "Use my example")]
        let adoptedID = try XCTUnwrap(state.plans?.first?.id)
        let lesson = try NivoCoachReducer.startToday(topicID: "topic", state: &state, now: now, zone: zone)
        XCTAssertEqual(lesson.topicID, "topic")
        XCTAssertEqual(lesson.chatSessionID, "chat")
        XCTAssertEqual(lesson.planID, adoptedID)
        XCTAssertEqual(state.sessions.first?.status, "sealed")
        XCTAssertEqual(state.sessions.first?.draft, "Draft for the earlier lesson")
        XCTAssertEqual(state.sessions.first?.planID, "earlier-plan")
        XCTAssertEqual(state.topics.first?.activeSessionID, lesson.id)
    }

    func testPrepCannotAdoptInventedQuoteOrChangePlanIdentity() throws {
        var state = state()
        try prompt(&state)
        let turn = try attempted(&state)
        let zone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let base = try NivoCoachLessonPlanRules.base(state, courseID: "course", now: 1_700_000_000_000,
            zone: zone, minutes: 15, need: "")
        let fields: [String: Any] = [
            "task": "Explain a boundary", "reason": "Check the previous response",
            "observe": "Describe the choice", "hints": ["Name the decision"],
            "branches": ["If unclear, ask who decides"], "check": "Apply it in a different situation",
            "criteriaIds": ["understanding"], "courseId": "another-course", "minutes": 120,
            "basis": [["sessionId": "lesson", "turnId": turn.id, "quote": "invented quote"]]
        ]
        let answer = String(decoding: try JSONSerialization.data(withJSONObject: fields), as: UTF8.self)
        var parsed = try NivoCoachLessonPlanRules.parse(answer, base: base)
        XCTAssertEqual(parsed.courseId, base.courseId)
        XCTAssertEqual(parsed.minutes, base.minutes)
        XCTAssertThrowsError(try NivoCoachLessonPlanRules.validate(parsed, state: state))
        parsed.basis[0].quote = "my responsibility"
        XCTAssertNoThrow(try NivoCoachLessonPlanRules.validate(parsed, state: state))
    }

    private func state() -> NivoCoachState {
        let criteria = [
            NivoCoachCriterion(id: "understanding", description: "Explain responsibility", dimension: "understanding"),
            NivoCoachCriterion(id: "application", description: "Apply in a new case", dimension: "application"),
            NivoCoachCriterion(id: "practice", description: "Report an actual action", requiresRealAction: true, dimension: "application")
        ]
        let unit = NivoCoachUnit(id: "u1", title: "Boundaries", focus: "Clarify responsibility", method: "Explain, compare, apply",
            criteria: criteria, source: "Self-authored exercise")
        let course = NivoCoachCourse(id: "course", title: "Boundaries", place: "Discussion", kind: .expression,
            units: [unit], version: "test-v1", source: "Self-authored")
        let topic = NivoCoachTopic(id: "topic", courseID: course.id, unitID: unit.id, title: "Evening request", caseText: "A favour", chatSessionID: "chat", activeSessionID: "lesson")
        let lesson = NivoCoachSession(id: "lesson", course: course, unitID: unit.id, chatSessionID: "chat", topicID: topic.id,
            teachingProtocol: "topic-v3", startedAt: 1)
        return NivoCoachState(tracks: [NivoCoachTrack(course: course, currentUnitID: unit.id)], sessions: [lesson], topics: [topic])
    }

    private func user(_ text: String = "My time is my responsibility", id: String = "user-row") -> NivoSavedUserTurn {
        NivoSavedUserTurn(id: id, text: text, ownerKey: "owner", chatSessionID: "chat", createdAt: 4)
    }

    private func prompt(_ state: inout NivoCoachState, visible: Bool = true) throws {
        let payload = try NivoCoachPayload.decode(#"{"mode":"practice","assessment":{"dimension":"understanding"}}"#)
        let response = try NivoCoachTeaching.reply(state.sessions[0], state: state, text: "Who is responsible for this choice?", payload: payload, now: 2)
        try state.replaceSession(response)
        if visible {
            try NivoCoachHostRules.recordReply(chatSessionID: "chat", messageID: "coach-row", text: "Who is responsible for this choice?",
                expectedSessionID: "lesson", state: &state, now: 3)
        }
    }

    private func attempted(_ state: inout NivoCoachState) throws -> NivoCoachTurn {
        let input = user()
        try NivoCoachHostRules.registerUser(input, expectedSessionID: "lesson", state: &state, now: 4)
        let marked = try NivoCoachTeaching.message(state.sessions[0], text: input.text, user: input, purpose: "attempt", now: 5)
        try state.replaceSession(marked)
        return try XCTUnwrap(state.sessions[0].turns.last { $0.role == "user" })
    }

    private func evidence(_ turn: NivoCoachTurn, criterion: String = "understanding") -> NivoCoachEvidence {
        NivoCoachEvidence(criterionID: criterion, turnID: turn.id, quote: turn.text, reason: "The response distinguishes responsibility", met: true)
    }

    func testHiddenToolQuestionCannotAuthorizeIndependentAttempt() throws {
        var state = state()
        try prompt(&state, visible: false)
        XCTAssertThrowsError(try attempted(&state))
    }

    func testUnboundLessonCannotTreatHiddenToolQuestionAsVisible() throws {
        var state = state()
        state.sessions[0].chatSessionID = ""
        try prompt(&state, visible: false)
        let assessment = try XCTUnwrap(state.sessions[0].assessment)
        XCTAssertFalse(NivoCoachTeaching.hasTraceableAssessment(state.sessions[0], id: assessment.id))
    }

    func testReplayedOlderUserMessageCannotAnswerLaterVisibleQuestion() throws {
        var state = state()
        try prompt(&state)
        var old = user()
        old = NivoSavedUserTurn(id: old.id, text: old.text, ownerKey: old.ownerKey, chatSessionID: old.chatSessionID, createdAt: 1)
        XCTAssertThrowsError(try NivoCoachTeaching.message(state.sessions[0], text: old.text, user: old, purpose: "attempt", now: 100))
    }

    func testVisibleQuestionBindsOriginalUserRowAndSeparateEvidenceDimension() throws {
        var state = state()
        try prompt(&state)
        let attempt = try attempted(&state)
        XCTAssertEqual(attempt.originMessageID, "user-row")
        XCTAssertEqual(attempt.purpose, "attempt")
        XCTAssertNoThrow(try NivoCoachTeaching.validate(evidence(attempt), session: state.sessions[0]))
        XCTAssertThrowsError(try NivoCoachTeaching.validate(evidence(attempt, criterion: "application"), session: state.sessions[0]))
        XCTAssertThrowsError(try NivoCoachTeaching.validate(evidence(attempt, criterion: "practice"), session: state.sessions[0]))
    }

    func testOrdinaryExplanationCannotBecomeIndependentEvidence() throws {
        var state = state()
        try NivoCoachHostRules.registerUser(user(), expectedSessionID: "lesson", state: &state, now: 4)
        XCTAssertThrowsError(try NivoCoachTeaching.message(state.sessions[0], text: user().text, user: user(), purpose: "attempt", now: 5))
    }

    func testDeletingQuestionInvalidatesItsAttemptAndEvidence() throws {
        var state = state()
        try prompt(&state)
        let attempt = try attempted(&state)
        state.sessions[0].evidence = [evidence(attempt)]
        XCTAssertTrue(NivoCoachTeaching.progress(state, topicID: "topic").hasUnderstanding)
        try NivoCoachHostRules.invalidateMessages(chatSessionID: "chat", messageIDs: ["coach-row"], state: &state)
        XCTAssertTrue(state.sessions[0].turns.first { $0.id == attempt.id }?.sourceInvalidated == true)
        XCTAssertTrue(state.sessions[0].evidence[0].disputed)
        XCTAssertFalse(NivoCoachTeaching.progress(state, topicID: "topic").hasUnderstanding)
    }

    func testDifferentFinalReplyInvalidatesHiddenAssessment() throws {
        var state = state()
        try prompt(&state, visible: false)
        try NivoCoachHostRules.recordReply(chatSessionID: "chat", messageID: "different-final", text: "Let us keep discussing the theory.",
            expectedSessionID: "lesson", state: &state, now: 3)
        XCTAssertNil(state.sessions[0].assessment)
        XCTAssertTrue(state.sessions[0].turns.first?.sourceInvalidated == true)
    }

    func testHintedAttemptCannotPass() throws {
        var state = state()
        try prompt(&state)
        state.sessions[0].nextSupport = "hinted"
        let attempt = try attempted(&state)
        XCTAssertThrowsError(try NivoCoachTeaching.validate(evidence(attempt), session: state.sessions[0]))
    }

    func testOrdinaryFollowUpDoesNotReopenCompletedLesson() throws {
        var state = state()
        state.sessions[0].status = "complete"
        state.sessions[0].endedAt = 3
        state.topics[0].activeSessionID = nil
        try NivoCoachHostRules.registerUser(user(), expectedSessionID: "lesson", state: &state, now: 4)
        try NivoCoachHostRules.recordReply(chatSessionID: "chat", messageID: "followup", text: "Here is another explanation.", expectedSessionID: "lesson", state: &state, now: 5)
        XCTAssertEqual(state.sessions.count, 1)
        XCTAssertEqual(state.sessions[0].status, "complete")
        XCTAssertEqual(state.sessions[0].endedAt, 3)
        XCTAssertNil(state.sessions[0].pendingTurnID)
    }

    func testOldLessonReplyCannotBeArchivedIntoNewLesson() throws {
        var state = state()
        state.sessions[0].status = "complete"
        state.topics[0].activeSessionID = nil
        _ = try NivoCoachReducer.startLesson(topicID: "topic", state: &state, now: 10)
        XCTAssertThrowsError(try NivoCoachHostRules.recordReply(chatSessionID: "chat", messageID: "late", text: "Old answer",
            expectedSessionID: "lesson", state: &state, now: 11))
        XCTAssertTrue(state.sessions.last?.turns.isEmpty == true)
    }

    func testFalseAndNullAssessmentAreOrdinaryTeaching() throws {
        XCTAssertNil(try NivoCoachPayload.decode(#"{"assessment":false}"#).assessment)
        XCTAssertNil(try NivoCoachPayload.decode(#"{"assessment":null}"#).assessment)
        XCTAssertThrowsError(try NivoCoachPayload.decode(#"{"assessment":true}"#))
    }

    func testNegatedAndQuestionedConfirmationCannotActivate() {
        for text in ["暂时不要确认", "还没确认", "是否可以确认？", "Do not confirm", "Please change this first"] {
            XCTAssertFalse(NivoCoachPolicy.confirms(text), text)
        }
        XCTAssertTrue(NivoCoachPolicy.confirms("确认，按这个方案创建课程"))
        XCTAssertTrue(NivoCoachPolicy.confirms("Confirm this proposal"))
    }

    /// 下一单元操作绑定用户看到的单元，不能因另一入口推进后再次跳过一节。
    func testAdvancingFromStaleDisplayedUnitDoesNotSkipAnotherUnit() throws {
        var state = state()
        var second = state.tracks[0].course.units[0]
        second.id = "u2"
        var third = second
        third.id = "u3"
        state.tracks[0].course.units += [second, third]
        state.tracks[0].currentUnitID = "u2"
        state.tracks[0].demonstrated = ["u1", "u2"]
        let before = state
        let request = NivoCoachCommand(action: "advance", operationID: "advance", expectedRevision: state.revision,
            targetID: "course", payload: #"{"unitId":"u1"}"#)
        let context = NivoCoachCommandContext(ownerKey: "test", generation: UUID(), isHost: true)
        XCTAssertThrowsError(try NivoCoachReducer.apply(request, context: context, state: &state, now: 10))
        XCTAssertEqual(state, before)
    }

    /// 当前课程的达标记录和下一单元均存在时才允许显式推进。
    func testAdvancingCurrentDemonstratedUnitMovesOnce() throws {
        var state = state()
        var next = state.tracks[0].course.units[0]
        next.id = "u2"
        state.tracks[0].course.units.append(next)
        state.tracks[0].demonstrated = ["u1"]
        let request = NivoCoachCommand(action: "advance", operationID: "advance", expectedRevision: state.revision,
            targetID: "course", payload: #"{"unitId":"u1"}"#)
        let context = NivoCoachCommandContext(ownerKey: "test", generation: UUID(), isHost: true)
        _ = try NivoCoachReducer.apply(request, context: context, state: &state, now: 10)
        XCTAssertEqual(state.tracks[0].currentUnitID, "u2")
        XCTAssertEqual(state.sessions.count, 1)
    }

    /// 页面展示之后课程被暂停，旧按钮不能继续推进课程。
    func testAdvancingPausedCoursePreservesCurrentUnit() throws {
        var state = state()
        var next = state.tracks[0].course.units[0]
        next.id = "u2"
        state.tracks[0].course.units.append(next)
        state.tracks[0].demonstrated = ["u1"]
        state.tracks[0].paused = true
        let before = state
        let request = NivoCoachCommand(action: "advance", operationID: "advance-paused", expectedRevision: state.revision,
            targetID: "course", payload: #"{"unitId":"u1"}"#)
        let context = NivoCoachCommandContext(ownerKey: "test", generation: UUID(), isHost: true)
        XCTAssertThrowsError(try NivoCoachReducer.apply(request, context: context, state: &state, now: 10))
        XCTAssertEqual(state, before)
    }

    /// 课程或任一单元待复核时，旧达标集合不能绕过复核入口。
    func testAdvancingUnreviewedCoursePreservesCurrentUnit() throws {
        for courseNeedsReview in [true, false] {
            var state = state()
            var next = state.tracks[0].course.units[0]
            next.id = "u2"
            state.tracks[0].course.units.append(next)
            state.tracks[0].demonstrated = ["u1"]
            state.tracks[0].course.needsCriteriaReview = courseNeedsReview
            state.tracks[0].course.units[1].needsCriteriaReview = !courseNeedsReview
            let before = state
            let request = NivoCoachCommand(action: "advance", operationID: "advance-review", expectedRevision: state.revision,
                targetID: "course", payload: #"{"unitId":"u1"}"#)
            let context = NivoCoachCommandContext(ownerKey: "test", generation: UUID(), isHost: true)
            XCTAssertThrowsError(try NivoCoachReducer.apply(request, context: context, state: &state, now: 10))
            XCTAssertEqual(state, before)
        }
    }
}
