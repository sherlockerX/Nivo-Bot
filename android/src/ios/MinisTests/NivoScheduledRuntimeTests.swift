import XCTest
@testable import Minis

/// 可信上报必须绑定宿主授予的执行上下文，不接受来宾填写的身份。
final class NivoScheduledRuntimeTests: XCTestCase {
    func testScheduledRetryKeepsEditReservationAfterItsRunExpires() throws {
        let scopes = NivoScheduledRunScopes()
        let lease = try scopes.enter(taskID: "task", runID: UUID().uuidString,
            sessionID: "chat", owner: "local", isScript: false)
        let edit = try scopes.beginConversationEdit(["chat"], scheduledRunID: lease.runID)
        XCTAssertFalse(scopes.canStart(sessionID: "chat", runID: lease.runID))
        scopes.leave(lease)
        XCTAssertTrue(scopes.isBusy)
        XCTAssertFalse(scopes.canStart(sessionID: "chat", runID: nil))
        scopes.endConversationEdit(edit)
        XCTAssertFalse(scopes.canStart(sessionID: "chat", runID: lease.runID))
        XCTAssertTrue(scopes.canStart(sessionID: "chat", runID: nil))
    }

    func testScheduledRetryCannotBorrowAnotherRunOrScriptLease() throws {
        let scopes = NivoScheduledRunScopes()
        let lease = try scopes.enter(taskID: "task", runID: UUID().uuidString,
            sessionID: "chat", owner: "local", isScript: false)
        XCTAssertThrowsError(try scopes.beginConversationEdit(["chat"], scheduledRunID: UUID().uuidString))
        XCTAssertThrowsError(try scopes.beginConversationEdit(["chat", "other"], scheduledRunID: lease.runID))
        scopes.leave(lease)
        let script = try scopes.enter(taskID: "script", runID: UUID().uuidString,
            sessionID: "chat", owner: "local", isScript: true)
        XCTAssertThrowsError(try scopes.beginConversationEdit(["chat"], scheduledRunID: script.runID))
        scopes.leave(script)
        XCTAssertFalse(scopes.isBusy)
    }

    func testSignedOutLocalOwnerCanRunAndReportWithoutCloudAccount() throws {
        // NanoMuseAccountData.local的真实标识是空字符串，不能误当作缺少账户。
        let scopes = NivoScheduledRunScopes()
        let lease = try scopes.enter(taskID: "local-task", runID: UUID().uuidString,
            sessionID: "local-session", owner: "", isScript: true)
        defer { scopes.leave(lease) }
        try scopes.bind(context: 9, to: lease)
        let report = try scopes.report(context: 9, status: "success", reason: nil, result: "Local result")
        XCTAssertEqual(lease.owner, "")
        XCTAssertEqual(report.status, "success")
    }

    func testConversationEditsAndRunsExcludeEachOtherUntilTheirOwnRelease() throws {
        let scopes = NivoScheduledRunScopes()
        let edit = try scopes.beginConversationEdit(["one", "two"])
        XCTAssertTrue(scopes.isBusy)
        XCTAssertFalse(scopes.canStart(sessionID: "one", runID: nil))
        XCTAssertThrowsError(try scopes.beginConversationEdit(["two", "three"]))
        XCTAssertTrue(scopes.canStart(sessionID: "three", runID: nil), "失败的批量申请不能留下部分占位")
        XCTAssertThrowsError(try scopes.enter(taskID: "task", runID: UUID().uuidString,
            sessionID: "one", owner: "local", isScript: true))
        scopes.endConversationEdit(UUID())
        XCTAssertFalse(scopes.canStart(sessionID: "two", runID: nil))
        scopes.endConversationEdit(edit)
        let lease = try scopes.enter(taskID: "task", runID: UUID().uuidString,
            sessionID: "one", owner: "local", isScript: true)
        XCTAssertThrowsError(try scopes.beginConversationEdit(["one"]))
        scopes.leave(lease)
        XCTAssertFalse(scopes.isBusy)
    }

    func testOrdinaryAndExpiredContextsCannotReport() throws {
        let scopes = NivoScheduledRunScopes()
        let lease = try scopes.enter(taskID: "task", runID: UUID().uuidString, sessionID: "session", owner: "local", isScript: true)
        XCTAssertThrowsError(try scopes.report(context: 1, status: "success", reason: nil, result: nil))
        try scopes.bind(context: 2, to: lease)
        let report = try scopes.report(context: 2, status: "success", reason: nil, result: "Actual result")
        XCTAssertEqual(report.result, "Actual result")
        scopes.unbind(context: 2)
        XCTAssertThrowsError(try scopes.report(context: 2, status: "failure", reason: nil, result: nil))
        scopes.leave(lease)
        XCTAssertThrowsError(try scopes.bind(context: 3, to: lease))
    }

    func testTaskAndSessionAreBothExclusiveAndOldLeaveCannotRevokeNewRun() throws {
        let scopes = NivoScheduledRunScopes()
        let first = try scopes.enter(taskID: "task", runID: UUID().uuidString, sessionID: "session", owner: "local", isScript: false)
        XCTAssertThrowsError(try scopes.enter(taskID: "task", runID: UUID().uuidString, sessionID: "other", owner: "local", isScript: false))
        XCTAssertThrowsError(try scopes.enter(taskID: "other", runID: UUID().uuidString, sessionID: "session", owner: "local", isScript: false))
        XCTAssertFalse(scopes.canStart(sessionID: "session", runID: nil))
        XCTAssertTrue(scopes.canStart(sessionID: "session", runID: first.runID))
        scopes.leave(first)
        let second = try scopes.enter(taskID: "task", runID: UUID().uuidString, sessionID: "session", owner: "local", isScript: false)
        scopes.leave(first)
        XCTAssertEqual(scopes.lease(sessionID: "session", runID: second.runID), second)
        XCTAssertNil(scopes.lease(sessionID: "session", runID: first.runID))
    }

    func testInvalidReportDoesNotOverwriteAcceptedEvidence() throws {
        let scopes = NivoScheduledRunScopes()
        let lease = try scopes.enter(taskID: "task", runID: UUID().uuidString, sessionID: "session", owner: "local", isScript: false)
        try scopes.bind(context: 7, to: lease)
        _ = try scopes.report(context: 7, status: "failure", reason: "No match", result: nil)
        XCTAssertThrowsError(try scopes.report(context: 7, status: "unknown", reason: nil, result: "Fake"))
        XCTAssertThrowsError(try scopes.report(context: 7, status: "success", reason: String(repeating: "界", count: 201), result: nil))
        XCTAssertThrowsError(try scopes.report(context: 7, status: nil, reason: nil, result: String(repeating: "界", count: 4001)))
        let accepted = try XCTUnwrap(scopes.snapshot(lease))
        XCTAssertEqual(accepted.status, "failure")
        XCTAssertEqual(accepted.reason, "No match")
        XCTAssertNil(accepted.result)
    }

    func testTransportFailureAndExitCodeOverrideEarlierSuccessReport() {
        let report = NivoScheduledReport(status: "success", reason: nil, result: "Result")
        XCTAssertEqual(report.outcome(failed: true, scriptExit: 0, outputRequired: false, hasOutput: true), "failure")
        XCTAssertEqual(report.outcome(failed: false, scriptExit: 7, outputRequired: false, hasOutput: true), "failure")
        XCTAssertEqual(report.outcome(failed: false, scriptExit: 0, outputRequired: true, hasOutput: false), "failure")
        XCTAssertEqual(NivoScheduledReport().outcome(failed: false, scriptExit: nil, outputRequired: false, hasOutput: false), "unknown")
        XCTAssertEqual(NivoScheduledReport().outcome(failed: false, scriptExit: 0, outputRequired: false, hasOutput: false), "success")
    }
}
