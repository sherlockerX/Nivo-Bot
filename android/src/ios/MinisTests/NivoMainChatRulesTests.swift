import XCTest
@testable import Minis

/// 最近训练或定时运行不能改变首页对话的用途，失效的固定项必须按普通聊天回退。
final class NivoMainChatRulesTests: XCTestCase {
    func testRecentDedicatedAndRemoteSessionsDoNotReplaceOrdinaryChat() {
        let rows = [candidate("ordinary", time: 1), candidate("coach", time: 3, source: "coach_practice"),
                    candidate("routine", time: 4, source: "nanomuse-routine"), candidate("remote", time: 5, remote: true)]
        XCTAssertEqual(NivoMainChatRules.select(rows, preferredID: nil), "ordinary")
        XCTAssertEqual(NivoMainChatRules.select(rows, preferredID: "coach"), "ordinary")
        XCTAssertEqual(NivoMainChatRules.select(rows, preferredID: "routine"), "ordinary")
        XCTAssertEqual(NivoMainChatRules.select(rows, preferredID: "remote"), "ordinary")
    }

    func testRememberedOrdinaryChatTakesPriorityOverRecency() {
        let rows = [candidate("older", time: 1), candidate("newer", time: 2, source: "shortcut")]
        XCTAssertEqual(NivoMainChatRules.select(rows, preferredID: "older"), "older")
        XCTAssertEqual(NivoMainChatRules.select(rows, preferredID: "deleted"), "newer")
    }

    func testOnlyDedicatedSessionsLeaveMainChatUnassigned() {
        let rows = [candidate("coach", time: 1, source: "coach_practice"),
                    candidate("routine", time: 2, source: "nanomuse-routine")]
        XCTAssertNil(NivoMainChatRules.select(rows, preferredID: "coach"))
        XCTAssertNil(NivoMainChatRules.select([], preferredID: "deleted"))
    }

    func testEqualTimestampsChooseTheSameSessionRegardlessOfDatabaseOrder() {
        let rows = [candidate("a", time: 1), candidate("b", time: 1)]
        XCTAssertEqual(NivoMainChatRules.select(rows, preferredID: nil),
                       NivoMainChatRules.select(Array(rows.reversed()), preferredID: nil))
    }

    private func candidate(_ identifier: String, time: TimeInterval, source: String? = nil,
                           remote: Bool = false) -> NivoMainChatRules.Candidate {
        .init(id: identifier, updatedAt: Date(timeIntervalSince1970: time), isRemote: remote, source: source)
    }
}
