import XCTest
@testable import Minis

/// 跳过配置后的本地使用不依赖模型、原账号或曾否发送消息。
final class NivoFirstRunPolicyTests: XCTestCase {
    func testSkippedInstallNeverReopensSetup() {
        XCTAssertFalse(NanoMuseFirstRun.needed(hasSessions: false, done: true))
        XCTAssertFalse(NanoMuseFirstRun.needed(hasSessions: true, done: true))
    }

    func testExistingConversationKeepsLocalHomeAccessible() {
        XCTAssertFalse(NanoMuseFirstRun.needed(hasSessions: true, done: false))
        XCTAssertTrue(NanoMuseFirstRun.needed(hasSessions: false, done: false))
    }

    func testSetupContainsOnlyModelNotificationAndLocalWelcomeStages() {
        XCTAssertEqual(NanoMuseFirstRun.stage(hasProviders: false, hasGroups: false, modelsSkipped: false), .welcome)
        XCTAssertEqual(NanoMuseFirstRun.stage(hasProviders: true, hasGroups: false, modelsSkipped: false), .models)
        XCTAssertEqual(NanoMuseFirstRun.stage(hasProviders: true, hasGroups: false, modelsSkipped: true, notificationsSeen: false), .notifications)
        XCTAssertEqual(NanoMuseFirstRun.stage(hasProviders: true, hasGroups: false, modelsSkipped: true), .meet)
        XCTAssertEqual(NanoMuseFirstRun.stage(hasProviders: true, hasGroups: true, modelsSkipped: false), .meet)
    }
}
