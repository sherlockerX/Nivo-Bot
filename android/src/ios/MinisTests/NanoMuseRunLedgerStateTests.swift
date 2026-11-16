import XCTest
@testable import Minis

/// 直接验证生产运行记录，覆盖页面退出、身份迁移和多个页面的查看交接。
final class NanoMuseRunLedgerStateTests: XCTestCase {
    private let context = NanoMuseRunLedgerContext(ownerKey: "test-account", generation: 1)

    func testCompletionAndFailureSurviveWithoutAView() {
        var state = NanoMuseRunLedgerState()
        state.bind(context)
        let success = UUID(), failure = UUID()
        state.begin(success, session: "successful")
        state.begin(failure, session: "failed")
        XCTAssertEqual(state.running, ["successful", "failed"])
        state.finish(success, outcome: .completed)
        state.finish(failure, outcome: .failed)
        XCTAssertTrue(state.running.isEmpty)
        XCTAssertEqual(state.outcomes, ["successful": true, "failed": false])
    }

    func testDraftMigrationPreservesViewingIdentity() {
        var state = NanoMuseRunLedgerState()
        let run = UUID(), viewer = UUID()
        state.begin(run, session: "draft")
        state.setViewing(viewer, session: "draft")
        state.rebind(run, session: "saved-session")
        XCTAssertEqual(state.running, ["saved-session"])
        state.finish(run, outcome: .completed)
        XCTAssertTrue(state.outcomes.isEmpty)
        state.setViewing(viewer, session: nil)
        state.begin(run, session: "saved-session")
        state.finish(run, outcome: .completed)
        XCTAssertEqual(state.outcomes, ["saved-session": true])
    }

    func testOldViewDisappearanceDoesNotClearNewViewRegistration() {
        var state = NanoMuseRunLedgerState()
        let oldView = UUID(), newView = UUID(), run = UUID()
        state.setViewing(oldView, session: "chat")
        state.setViewing(newView, session: "chat")
        state.setViewing(oldView, session: nil)
        state.begin(run, session: "chat")
        state.finish(run, outcome: .completed)
        XCTAssertNil(state.outcomes["chat"])
        state.setViewing(newView, session: nil)
        state.begin(run, session: "chat")
        state.finish(run, outcome: .failed)
        XCTAssertEqual(state.outcomes["chat"], false)
    }

    func testOpeningOneChatClearsOnlyItsResult() {
        var state = NanoMuseRunLedgerState()
        for chat in ["opened", "unread"] {
            let run = UUID()
            state.begin(run, session: chat)
            state.finish(run, outcome: .completed)
        }
        state.setViewing(UUID(), session: "opened")
        XCTAssertEqual(state.outcomes, ["unread": true])
    }

    func testManualStopDoesNotCreateSuccessOrFailure() {
        var state = NanoMuseRunLedgerState()
        let run = UUID()
        state.begin(run, session: "chat")
        state.finish(run, outcome: .failed)
        state.begin(run, session: "chat")
        XCTAssertNil(state.outcomes["chat"])
        state.finish(run, outcome: .cancelled)
        XCTAssertTrue(state.running.isEmpty)
        XCTAssertTrue(state.outcomes.isEmpty)
    }

    func testRepeatedCallbacksDoNotRebindOrRewriteFinishedRun() {
        var state = NanoMuseRunLedgerState()
        let run = UUID()
        state.begin(run, session: "original")
        state.begin(run, session: "unrelated")
        XCTAssertEqual(state.running, ["original"])
        state.finish(run, outcome: .failed)
        state.finish(run, outcome: .completed)
        state.rebind(run, session: "unrelated")
        XCTAssertEqual(state.outcomes, ["original": false])
    }

    func testAnotherLiveRunKeepsTheSessionRunning() {
        var state = NanoMuseRunLedgerState()
        let first = UUID(), second = UUID()
        state.begin(first, session: "chat")
        state.begin(second, session: "chat")
        state.finish(first, outcome: .completed)
        XCTAssertEqual(state.running, ["chat"])
        XCTAssertNil(state.outcomes["chat"])
        state.finish(second, outcome: .failed)
        XCTAssertTrue(state.running.isEmpty)
        XCTAssertEqual(state.outcomes["chat"], false)
    }

    func testAccountOrRestoreGenerationChangeClearsOldRunsAndViewers() {
        for next in [NanoMuseRunLedgerContext(ownerKey: "other", generation: 1),
                     NanoMuseRunLedgerContext(ownerKey: context.ownerKey, generation: 2),
                     NanoMuseRunLedgerContext(ownerKey: context.ownerKey, generation: nil)] {
            var state = NanoMuseRunLedgerState()
            state.bind(context)
            let oldRun = UUID(), completedRun = UUID()
            state.begin(completedRun, session: "completed")
            state.finish(completedRun, outcome: .completed)
            state.begin(oldRun, session: "running")
            state.setViewing(UUID(), session: "viewed")
            state.bind(context)
            XCTAssertEqual(state.running, ["running"])
            state.bind(next)
            XCTAssertTrue(state.running.isEmpty)
            XCTAssertTrue(state.outcomes.isEmpty)
            state.finish(oldRun, outcome: .completed)
            XCTAssertTrue(state.outcomes.isEmpty)
            let newRun = UUID()
            state.begin(newRun, session: "viewed")
            state.finish(newRun, outcome: .completed)
            XCTAssertEqual(state.outcomes["viewed"], true)
        }
    }

    func testLedgerEvictsOldestUnreadResultAndKeepsLatestCompletion() {
        var state = NanoMuseRunLedgerState()
        for index in 0..<257 {
            let run = UUID()
            state.begin(run, session: "chat-\(index)")
            state.finish(run, outcome: .completed)
        }
        XCTAssertEqual(state.outcomes.count, 256)
        XCTAssertNil(state.outcomes["chat-0"])
        XCTAssertEqual(state.outcomes["chat-256"], true)
        let repeated = UUID()
        state.begin(repeated, session: "chat-1")
        state.finish(repeated, outcome: .failed)
        let newest = UUID()
        state.begin(newest, session: "newest")
        state.finish(newest, outcome: .completed)
        XCTAssertEqual(state.outcomes.count, 256)
        XCTAssertNil(state.outcomes["chat-2"])
        XCTAssertEqual(state.outcomes["chat-1"], false)
    }
}
