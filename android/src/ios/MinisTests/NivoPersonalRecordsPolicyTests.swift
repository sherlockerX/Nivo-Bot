import XCTest
@testable import Minis

/// 真实点击来源与保存回合绑定，后台派发不能借后来出现的前台状态授权。
final class NivoPersonalRecordsPolicyTests: XCTestCase {
    private let scope = NivoLifeScope(ownerKey: "owner", generation: 4)

    func testDraftPromotionRequiresSameHostAccountAndDraft() {
        let origin = NivoUserTurnOrigin.capture(hostID: "host", sessionID: nil, draftID: "draft",
            scope: scope, isForeground: true, isVisible: true, isDispatch: false)
        XCTAssertNotNil(origin)
        XCTAssertTrue(origin!.canBind(hostID: "host", sessionID: "saved", draftID: "draft", scope: scope, messageID: "row"))
        XCTAssertFalse(origin!.canBind(hostID: "other", sessionID: "saved", draftID: "draft", scope: scope, messageID: "row"))
        XCTAssertFalse(origin!.canBind(hostID: "host", sessionID: "saved", draftID: "other", scope: scope, messageID: "row"))
        XCTAssertFalse(origin!.canBind(hostID: "host", sessionID: "saved", draftID: "draft",
            scope: .init(ownerKey: "owner", generation: 5), messageID: "row"))
    }

    func testHeadlessBackgroundAndMixedQueueCannotGainPermission() {
        XCTAssertNil(NivoUserTurnOrigin.capture(hostID: "h", sessionID: "c", draftID: "d", scope: scope,
            isForeground: true, isVisible: true, isDispatch: true))
        XCTAssertNil(NivoUserTurnOrigin.capture(hostID: "h", sessionID: "c", draftID: "d", scope: scope,
            isForeground: false, isVisible: true, isDispatch: false))
        let origin = NivoUserTurnOrigin.capture(hostID: "h", sessionID: "c", draftID: "d", scope: scope,
            isForeground: true, isVisible: true, isDispatch: false)
        XCTAssertEqual(NivoUserTurnOrigin.merged([origin, origin]), origin)
        XCTAssertNil(NivoUserTurnOrigin.merged([origin, nil]))
        XCTAssertNil(NivoUserTurnOrigin.merged([]))
    }

    func testAuthorizationRequiresExactLoopAndSavedRowDigest() {
        let user = NivoSavedUserTurn(id: "row", text: "read my records", ownerKey: scope.ownerKey,
            chatSessionID: "chat", createdAt: 1, sourceDigest: "digest")
        let token = NivoPersonalRecordsAuthorization(hostID: "host", turnID: UUID(), scope: scope, user: user)
        XCTAssertTrue(token.matches(hostID: "host", turnID: token.turnID, scope: scope, user: user))
        XCTAssertFalse(token.matches(hostID: "host", turnID: UUID(), scope: scope, user: user))
        var edited = user
        edited.sourceDigest = "edited"
        XCTAssertFalse(token.matches(hostID: "host", turnID: token.turnID, scope: scope, user: edited))
    }
}
