import XCTest
import UIKit
@testable import Minis

/// 真正宿主注册和执行入口拒绝无来源的模型请求，不能仅凭工具名读取个人数据。
final class NivoPersonalRecordsHostTests: XCTestCase {
    @MainActor
    func testUnknownCallerCannotRegisterOrExecutePersonalTools() async {
        let host = AIChatViewModel()
        host.nmPersonalRecordsVisible = true
        let tools = host.makeAgentTools()
        XCTAssertFalse(tools.contains { $0.name == NivoPersonalRecordsToolBridge.name })
        XCTAssertFalse(tools.contains { $0.name == NivoLifeToolBridge.todoQuery })
        do {
            _ = try await NivoPersonalRecordsToolBridge.execute(args: ["kind": "catalog"], host: host, authorization: nil)
            XCTFail("无真实回合来源应拒绝")
        } catch { }
    }

    @MainActor
    func testNewTurnRevokesPriorAuthorizationEvenWithSameAccountAndSession() {
        let host = AIChatViewModel()
        let user = NivoSavedUserTurn(id: "row", text: "read", ownerKey: "owner", chatSessionID: "chat", createdAt: 1)
        let token = NivoPersonalRecordsAuthorization(hostID: host.nmPersonalRecordsHostID,
            turnID: host.nmPersonalRecordsTurnID, scope: .init(ownerKey: "owner", generation: 1), user: user)
        host.nmPersonalRecordsAuthorization = token
        let next = host.nmBeginRecordsTurn()
        XCTAssertNotEqual(next, token.turnID)
        XCTAssertNil(host.nmPersonalRecordsAuthorization)
        XCTAssertFalse(host.makeAgentTools(recordsAuthorization: token).contains { $0.name == NivoPersonalRecordsToolBridge.name })
    }

    @MainActor
    func testForegroundNotificationRevokesImmediatelyWithoutCancellingChat() {
        let host = AIChatViewModel()
        host.nmPersonalRecordsVisible = true
        let turn = host.nmPersonalRecordsTurnID
        let visibility = host.nmPersonalRecordsVisibilityID
        let scope = NivoLifeScope(ownerKey: "owner", generation: 1)
        host.nmPendingUserOrigin = NivoUserTurnOrigin.capture(hostID: host.nmPersonalRecordsHostID,
            sessionID: nil, draftID: "draft", scope: scope, isForeground: true, isVisible: true,
            isDispatch: false, visibilityID: visibility)
        let user = NivoSavedUserTurn(id: "row", text: "read", ownerKey: "owner", chatSessionID: "chat", createdAt: 1)
        host.nmPersonalRecordsAuthorization = .init(hostID: host.nmPersonalRecordsHostID, turnID: turn,
            scope: scope, user: user, visibilityID: visibility)
        NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
        XCTAssertNil(host.nmPersonalRecordsAuthorization)
        XCTAssertNil(host.nmPendingUserOrigin)
        XCTAssertNotEqual(host.nmPersonalRecordsVisibilityID, visibility)
        XCTAssertEqual(host.nmPersonalRecordsTurnID, turn)
        XCTAssertFalse(host.userDidCancel)
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        XCTAssertNil(host.nmPersonalRecordsAuthorization)
    }

    @MainActor
    func testPageHideShowDoesNotReviveCapturedButtonOrigin() throws {
        let host = AIChatViewModel()
        host.nmPersonalRecordsVisible = true
        let scope = NivoLifeScope(ownerKey: "owner", generation: 1)
        let origin = try XCTUnwrap(NivoUserTurnOrigin.capture(hostID: host.nmPersonalRecordsHostID,
            sessionID: "chat", draftID: "draft", scope: scope, isForeground: true, isVisible: true,
            isDispatch: false, visibilityID: host.nmPersonalRecordsVisibilityID))
        let turn = host.nmPersonalRecordsTurnID
        host.nmPersonalRecordsVisible = false
        host.nmPersonalRecordsVisible = true
        XCTAssertFalse(origin.canBind(hostID: host.nmPersonalRecordsHostID, sessionID: "chat", draftID: "draft",
            scope: scope, messageID: "row", visibilityID: host.nmPersonalRecordsVisibilityID))
        XCTAssertEqual(host.nmPersonalRecordsTurnID, turn)
        XCTAssertFalse(host.userDidCancel)
    }

    @MainActor
    func testActualOffloadingKeepsPersonalHistoryAndDirectWriterRefusesIt() {
        let host = AIChatViewModel()
        let secret = String(repeating: "Private record ", count: 100)
        let names = NivoPersonalRecordsPrivacy.toolNames.sorted()
        host.agentHistory = names.map { name in
            AgentMessage(role: .user, parts: [.toolResult(id: name, name: name, content: secret, isError: false)])
        } + (0..<4).map { AgentMessage(role: .assistant, parts: [.text("Recent \($0)")]) }
        host.offloadContextIfNeeded(model: .claudeSonnet46, lastContextTokens: 100_000, force: true)
        for (index, name) in names.enumerated() {
            guard case .toolResult(_, let storedName, let content, _, _, _, _, _) = host.agentHistory[index].parts[0] else {
                XCTFail("个人记录必须保留结构化结果"); continue
            }
            XCTAssertEqual(storedName, name)
            XCTAssertEqual(content, secret)
            XCTAssertTrue(host.offloadToolOutput(secret, toolName: name, toolId: "private-test").linuxPath.isEmpty)
        }
    }
}
