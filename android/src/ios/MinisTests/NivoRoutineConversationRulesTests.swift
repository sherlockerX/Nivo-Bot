import XCTest
@testable import Minis

/// 专属对话在重试、改名、切号和旧档案加载时保持明确身份。
final class NivoRoutineConversationRulesTests: XCTestCase {
    func testStableIdentitySeparatesOwnersAndAmbiguousComponents() {
        let identifier = NivoRoutineConversationRules.initialSession(owner: "a", routineID: "b:c")
        XCTAssertNotNil(UUID(uuidString: identifier))
        XCTAssertEqual(identifier, NivoRoutineConversationRules.initialSession(owner: "a", routineID: "b:c"))
        XCTAssertNotEqual(identifier, NivoRoutineConversationRules.initialSession(owner: "a:b", routineID: "c"))
        XCTAssertNotEqual(identifier, NivoRoutineConversationRules.initialSession(owner: "other", routineID: "b:c"))
        XCTAssertNotEqual(NivoRoutineConversationRules.folder(owner: "a"), NivoRoutineConversationRules.folder(owner: "b"))
    }

    func testBuiltInAndFollowUpTasksDoNotBecomeUserDedicatedConversations() {
        var row = NanoMuseRoutine(label: "Task", prompt: "Prompt", hour: 8, minute: 0)
        XCTAssertTrue(NivoRoutineConversationRules.usesDedicatedConversation(row))
        row.hidden = true
        XCTAssertFalse(NivoRoutineConversationRules.usesDedicatedConversation(row))
        row.hidden = false
        row.goalId = "goal"
        XCTAssertFalse(NivoRoutineConversationRules.usesDedicatedConversation(row))
        row.goalId = nil
        row.sessionId = UUID().uuidString
        XCTAssertFalse(NivoRoutineConversationRules.usesDedicatedConversation(row))
        row.execution = NivoRoutineExecution(target: .newSession)
        XCTAssertTrue(NivoRoutineConversationRules.usesDedicatedConversation(row))
    }

    func testLegacyArchiveAndRenamedTaskKeepReservedConversation() throws {
        var row = NanoMuseRoutine(label: "Before", prompt: "Prompt", hour: 8, minute: 0)
        let legacy = try JSONDecoder().decode(NanoMuseRoutine.self, from: JSONEncoder().encode(row))
        XCTAssertNil(legacy.dedicatedSessionID)
        row.dedicatedSessionID = UUID().uuidString
        row.label = "After"
        let restored = try JSONDecoder().decode(NanoMuseRoutine.self, from: JSONEncoder().encode(row))
        XCTAssertEqual(restored.dedicatedSessionID, row.dedicatedSessionID)
        XCTAssertEqual(restored.label, "After")
    }

    func testInvalidReservedConversationIsRejected() {
        var row = NanoMuseRoutine(label: "Task", prompt: "Prompt", hour: 8, minute: 0)
        row.dedicatedSessionID = "../other"
        XCTAssertThrowsError(try NivoRoutineScheduleRules.validate(row))
    }
}
