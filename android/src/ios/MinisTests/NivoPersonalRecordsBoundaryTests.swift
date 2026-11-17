import XCTest
@testable import Minis

/// 专题裁剪与隐私策略直接覆盖生产入口共用的规则。
final class NivoPersonalRecordsBoundaryTests: XCTestCase {
    func testZeroMillisecondReflectionEvidenceRemainsZeroInJSONAndMarkdown() throws {
        var state = NivoMosaicState(ownerKey: "owner")
        var entry = NivoMosaicEntry(ownerKey: "owner", id: "reflection", day: 1, text: "Immediate finish",
            taskIDs: [], focusIDs: ["zero"], createdAt: 1, updatedAt: 1)
        entry.reflectionSessionID = "zero"
        entry.focusSnapshots = [.init(id: "zero", title: "No measured time", elapsedMs: 0, startedAt: 0, endedAt: 0)]
        state.entries = [entry]
        let query = try NivoJigsawQuery.parse(["get", "--date", "1970-01-02"])
        let output = try NivoJigsawOutput.render(query: query, state: state)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        let day = try XCTUnwrap((root["days"] as? [[String: Any]])?.first)
        let record = try XCTUnwrap((day["records"] as? [[String: Any]])?.first)
        let focus = try XCTUnwrap((record["focusSnapshots"] as? [[String: Any]])?.first)
        XCTAssertEqual(focus["elapsedMs"] as? Int, 0)
        XCTAssertEqual(focus["startedAt"] as? Int, 0)
        XCTAssertEqual(focus["endedAt"] as? Int, 0)
        let markdown = try NivoJigsawQuery.parse(["get", "--date", "1970-01-02", "--format", "md"])
        XCTAssertTrue(try NivoJigsawOutput.render(query: markdown, state: state).contains("elapsedMs=0; startedAt=0; endedAt=0"))
    }

    func testOrdinaryConversationCanReadCurrentAccountSnapshot() throws {
        let state = fixture()
        let visible = try NivoPersonalRecordsCoachScope.visible(state, chatID: "ordinary", requiresTopic: false)
        XCTAssertEqual(visible, state)
    }

    func testSavedBindingRestrictsTopicEvenWithoutCachedPracticeContext() throws {
        let state = fixture()
        let visible = try NivoPersonalRecordsCoachScope.visible(state, chatID: "chat-a", requiresTopic: false)
        XCTAssertEqual(visible.topics.map(\.id), ["topic-a"])
        XCTAssertEqual(visible.tracks.map(\.id), ["course-a"])
        XCTAssertEqual(visible.sessions.map(\.id), ["lesson-a"])
        XCTAssertEqual(visible.actions.map(\.id), ["action-a"])
        XCTAssertTrue(visible.drafts.isEmpty)
        XCTAssertTrue(visible.operations.isEmpty)
        let request = try NivoPersonalRecordsRequest.parse(["kind": "coach", "section": "topics", "targetId": "topic-b"])
        XCTAssertThrowsError(try NivoPersonalRecordsOutput.coach(request, state: visible))
        let overview = try NivoPersonalRecordsRequest.parse(["kind": "coach", "section": "overview"])
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(NivoPersonalRecordsOutput.coach(overview, state: visible).utf8)) as? [String: Any])
        let data = try XCTUnwrap(root["data"] as? [String: Any])
        XCTAssertEqual(data["topics"] as? Int, 1)
        XCTAssertEqual(data["drafts"] as? Int, 0)
    }

    func testMissingOrAmbiguousPracticeBindingCannotBecomeGlobalRead() throws {
        var state = fixture()
        XCTAssertThrowsError(try NivoPersonalRecordsCoachScope.visible(state, chatID: "missing", requiresTopic: true))
        XCTAssertThrowsError(try NivoPersonalRecordsCoachScope.visible(state, chatID: "", requiresTopic: false))
        state.topics[1].chatSessionID = "chat-a"
        XCTAssertThrowsError(try NivoPersonalRecordsCoachScope.visible(state, chatID: "chat-a", requiresTopic: false))
    }

    func testEveryPersonalToolOmitsBodyFromTraceAndRejectsOffload() {
        let secret = "PRIVATE_HEAD" + String(repeating: "record ", count: 100) + "PRIVATE_TAIL"
        for name in NivoPersonalRecordsPrivacy.toolNames {
            let trace = NivoPersonalRecordsPrivacy.historySummary(id: "tool-id", name: name, content: secret,
                isError: true, hasImage: false)
            XCTAssertFalse(trace.contains("PRIVATE_HEAD"))
            XCTAssertFalse(trace.contains("PRIVATE_TAIL"))
            XCTAssertTrue(trace.contains(name))
            XCTAssertTrue(trace.contains("[ERROR]"))
            XCTAssertFalse(NivoPersonalRecordsPrivacy.canOffload(name))
        }
        XCTAssertTrue(NivoPersonalRecordsPrivacy.canOffload("shell_execute"))
        XCTAssertTrue(NivoPersonalRecordsPrivacy.historySummary(id: "shell", name: "shell_execute", content: secret,
            isError: false, hasImage: false).contains("PRIVATE_HEAD"))
    }

    func testCapturedClickCannotBindAfterQuickBackgroundForegroundRoundTrip() throws {
        let scope = NivoLifeScope(ownerKey: "owner", generation: 2)
        let capturedVisibility = UUID()
        let origin = try XCTUnwrap(NivoUserTurnOrigin.capture(hostID: "host", sessionID: nil, draftID: "draft",
            scope: scope, isForeground: true, isVisible: true, isDispatch: false, visibilityID: capturedVisibility))
        XCTAssertTrue(origin.canBind(hostID: "host", sessionID: "saved", draftID: "draft", scope: scope,
            messageID: "row", visibilityID: capturedVisibility))
        XCTAssertFalse(origin.canBind(hostID: "host", sessionID: "saved", draftID: "draft", scope: scope,
            messageID: "row", visibilityID: UUID()))
    }

    private func fixture() -> NivoCoachState {
        var state = NivoCoachState()
        for suffix in ["a", "b"] {
            let course = NivoCoachCourse(id: "course-" + suffix, title: "Course " + suffix, place: "test",
                kind: .custom, units: [], version: "1")
            state.tracks.append(.init(course: course, currentUnitID: "unit"))
            state.topics.append(.init(id: "topic-" + suffix, courseID: course.id, unitID: "unit",
                title: "Topic " + suffix, caseText: "Private case " + suffix, chatSessionID: "chat-" + suffix))
            var lesson = NivoCoachSession(id: "lesson-" + suffix, course: course, unitID: "unit")
            lesson.topicID = "topic-" + suffix
            state.sessions.append(lesson)
            state.actions.append(.init(id: "action-" + suffix, sessionID: lesson.id, plan: "Private plan"))
        }
        state.drafts = [.init(id: "draft", text: "Private draft", course: nil)]
        state.operations = ["receipt": "Private receipt"]
        return state
    }
}
