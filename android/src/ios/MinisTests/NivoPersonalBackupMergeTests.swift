import XCTest
@testable import Minis

/// 合并针对真实值模型验证冲突、墓碑与计时，不触碰正式账户。
final class NivoPersonalBackupMergeTests: XCTestCase {
    private func task(_ title: String, revision: Int64 = 1) -> NivoTodoTask {
        NivoTodoTask(ownerKey: "source", id: "task", title: title, revision: revision,
                     createdAt: 1, updatedAt: revision)
    }

    func testImportedRecordsAreReboundButReceiptsAreNot() throws {
        var incoming = NivoLifeState(ownerKey: "source")
        incoming.tasks = [task("Read")]
        incoming.operations["remote"] = NivoLifeOperation(request: Data(), result: Data())
        let result = try NivoPersonalBackupMerge.life(local: NivoLifeState(ownerKey: ""), incoming: incoming, owner: "")
        XCTAssertEqual(result.tasks.first?.ownerKey, "")
        XCTAssertTrue(result.operations.isEmpty)
        XCTAssertEqual(result.ownerKey, "")
    }

    func testEqualRevisionConflictDoesNotSilentlyOverwrite() throws {
        var local = NivoLifeState(ownerKey: "source")
        local.tasks = [task("Local")]
        var incoming = local
        incoming.tasks[0].title = "Other device"
        XCTAssertThrowsError(try NivoPersonalBackupMerge.life(local: local, incoming: incoming, owner: "source"))
        XCTAssertEqual(local.tasks[0].title, "Local")
    }

    func testDeletedTaskCannotBeResurrectedByBackup() throws {
        var incoming = NivoLifeState(ownerKey: "source")
        incoming.tasks = [task("Read")]
        var local = incoming
        local.tasks[0].deletedAt = 10
        local.tasks[0].revision = 2
        let result = try NivoPersonalBackupMerge.life(local: local, incoming: incoming, owner: "source")
        XCTAssertEqual(result.tasks[0].deletedAt, 10)
    }

    func testImportedRunningClockIsHistoryWithoutUnmeasuredTime() throws {
        let sample = NivoFocusClockSample(wallMs: 100_000, elapsedMs: 10, bootID: "old-device")
        var incoming = NivoLifeState(ownerKey: "source")
        incoming.focusSessions = [try NivoFocusRules.start(owner: "source", id: "focus", title: "Read",
            task: nil, mode: .pomodoro, minutes: 3, clock: sample)]
        let result = try NivoPersonalBackupMerge.life(local: NivoLifeState(ownerKey: ""), incoming: incoming, owner: "")
        let restored = try XCTUnwrap(result.focusSessions.first)
        XCTAssertEqual(restored.status, .finished)
        XCTAssertEqual(restored.elapsedMs, 0)
        XCTAssertTrue(result.focusSpans.isEmpty)
        XCTAssertFalse(restored.isActive)
    }

    func testLocalActiveTimerWinsOverItsPortablePausedCopy() throws {
        let start = NivoFocusClockSample(wallMs: 100_000, elapsedMs: 10, bootID: "device")
        var local = NivoLifeState(ownerKey: "source")
        let active = try NivoFocusRules.start(owner: "source", id: "focus", title: "Read",
            task: nil, mode: .pomodoro, minutes: 3, clock: start)
        local.focusSessions = [active]
        let paused = try NivoFocusRules.mutate(active, action: "pause", expectedRevision: 1,
            clock: NivoFocusClockSample(wallMs: 105_000, elapsedMs: 5_010, bootID: "device"), spanID: "span")
        var incoming = local
        incoming.focusSessions = [paused.session]
        incoming.focusSpans = [try XCTUnwrap(paused.span)]
        let result = try NivoPersonalBackupMerge.life(local: local, incoming: incoming, owner: "source")
        XCTAssertEqual(result.focusSessions, local.focusSessions)
        XCTAssertEqual(result.focusSpans, local.focusSpans)
    }
}
