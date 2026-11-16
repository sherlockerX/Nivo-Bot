import XCTest
@testable import Minis

/// 使用真实导航状态机验证来源身份和页面时序，不以正文搜索代替原消息ID。
final class NivoCoachSourceNavigationTests: XCTestCase {
    private let scope = NivoLifeScope(ownerKey: "test", generation: 1)

    func testWaitsForCorrectVisibleLoadedConversation() {
        var state = NivoCoachSourceNavigationState()
        XCTAssertTrue(state.enqueue(chatID: "practice", messageID: "database-row", scope: scope))
        let target = NivoCoachSourceMessageTarget(id: UUID(), sourceIDs: ["database-row"])
        for (chat, ready, visible) in [("other", true, true), ("practice", false, true), ("practice", true, false)] {
            XCTAssertEqual(state.decision(scope: scope, chatID: chat, isReady: ready, isVisible: visible, messages: [target]), .waiting)
            XCTAssertNotNil(state.pending)
        }
        XCTAssertEqual(state.decision(scope: scope, chatID: "practice", isReady: true, isVisible: true, messages: [target]), .scroll(target.id))
    }

    func testMergedAssistantRowsResolveToTheirSharedDisplayIdentity() {
        var state = NivoCoachSourceNavigationState()
        let target = NivoCoachSourceMessageTarget(id: UUID(), sourceIDs: ["explanation", "final-answer"])
        _ = state.enqueue(chatID: "practice", messageID: "final-answer", scope: scope)
        XCTAssertEqual(state.decision(scope: scope, chatID: "practice", isReady: true, isVisible: true, messages: [target]), .scroll(target.id))
    }

    func testAbsentAndAmbiguousSourcesAreUnavailable() {
        var state = NivoCoachSourceNavigationState()
        _ = state.enqueue(chatID: "practice", messageID: "source", scope: scope)
        XCTAssertEqual(state.decision(scope: scope, chatID: "practice", isReady: true, isVisible: true, messages: []), .unavailable)
        let targets = (0..<2).map { _ in NivoCoachSourceMessageTarget(id: UUID(), sourceIDs: ["source"]) }
        XCTAssertEqual(state.decision(scope: scope, chatID: "practice", isReady: true, isVisible: true, messages: targets), .unavailable)
    }

    func testAccountChangeAndSameAccountRestoreDiscardPendingNavigation() {
        for changed in [NivoLifeScope(ownerKey: "other", generation: 1), NivoLifeScope(ownerKey: "test", generation: 2)] {
            var state = NivoCoachSourceNavigationState()
            _ = state.enqueue(chatID: "practice", messageID: "source", scope: scope)
            XCTAssertEqual(state.decision(scope: changed, chatID: "practice", isReady: true, isVisible: true, messages: []), .discarded)
            state.invalidate(unless: changed)
            XCTAssertNil(state.pending)
        }
    }

    func testConsumptionIsOnceAndOldCallbackCannotConsumeNewerRequest() throws {
        var state = NivoCoachSourceNavigationState()
        _ = state.enqueue(chatID: "practice", messageID: "first", scope: scope)
        let first = try XCTUnwrap(state.pending?.id)
        _ = state.enqueue(chatID: "practice", messageID: "second", scope: scope)
        state.consume(first)
        XCTAssertEqual(state.pending?.messageID, "second")
        state.consume(try XCTUnwrap(state.pending?.id))
        XCTAssertNil(state.pending)
        XCTAssertEqual(state.decision(scope: scope, chatID: "practice", isReady: true, isVisible: true, messages: []), .waiting)
    }
}
