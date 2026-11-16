import XCTest
@testable import Minis

/// 授权身份必须来自持久化原话，而不是模型转述或界面随机ID。
final class NivoSavedUserTurnTests: XCTestCase {
    func testSavedDatabaseIdentitySurvivesUIRecreation() {
        let row = RawMessage(id: "saved-user", sessionId: "chat", role: .user,
                             parts: [.text("这个任务做完了")], createdAt: Date(timeIntervalSince1970: 100))
        let evidence = NivoUserTurnEvidence.validated(row, text: "这个任务做完了", sessionID: "chat", owner: "one")
        XCTAssertEqual(evidence?.id, "saved-user")
        XCTAssertEqual(evidence?.createdAt, 100_000)
        XCTAssertEqual(evidence?.ownerKey, "one")
    }

    func testAnotherConversationOrParaphraseCannotAuthorizeMutation() {
        let row = RawMessage(id: "saved-user", sessionId: "chat", role: .user,
                             parts: [.text("我准备做这个任务")], createdAt: Date())
        XCTAssertNil(NivoUserTurnEvidence.validated(row, text: "我准备做这个任务", sessionID: "other", owner: "one"))
        XCTAssertNil(NivoUserTurnEvidence.validated(row, text: "这个任务已经完成", sessionID: "chat", owner: "one"))
    }

    func testAssistantTextCannotBecomeUserEvidence() {
        let row = RawMessage(id: "reply", sessionId: "chat", role: .assistant,
                             parts: [.text("这个任务做完了")], createdAt: Date())
        XCTAssertNil(NivoUserTurnEvidence.validated(row, text: "这个任务做完了", sessionID: "chat", owner: "one"))
    }
}
