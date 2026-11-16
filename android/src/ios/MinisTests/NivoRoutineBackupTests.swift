import XCTest
@testable import Minis

/// 恢复只搬运资料，不恢复执行意图或覆盖同名本机任务。
final class NivoRoutineBackupTests: XCTestCase {
    private func row(_ identifier: String = "routine") -> NanoMuseRoutine {
        NanoMuseRoutine(id: identifier, label: "Saved routine", prompt: "Review the day", hour: 9, minute: 0)
    }

    private func backup(_ rows: [NanoMuseRoutine], paths: [String] = []) -> NivoRoutineBackup {
        NivoRoutineBackup(routines: rows, settings: NivoRoutineNotificationSettings(), homePaths: paths)
    }

    func testImportedQueueCannotExecuteAndHistoryKeepsDeliveryError() throws {
        var saved = row()
        saved.pendingRun = NivoRoutinePendingRun(queuedAt: Date())
        saved.runs = [NanoMuseRoutine.Run(at: Date(), ok: true, id: UUID().uuidString,
            status: "success", exitCode: 0, stdoutBytes: 35, deliveryError: "disk full")]
        let document = backup([saved])
        let decoded = try JSONDecoder().decode(NivoRoutineBackup.self, from: JSONEncoder().encode(document))
        let merged = try decoded.merging(into: [])
        let imported = try XCTUnwrap(merged.routines.first)
        XCTAssertFalse(imported.enabled)
        XCTAssertNil(imported.pendingRun)
        XCTAssertFalse(imported.isDue(at: .distantFuture))
        XCTAssertEqual(imported.runs, saved.runs)
    }

    func testRunningHistoryBecomesInterruptedWithoutInventedEndTime() throws {
        var saved = row()
        saved.runs = [NanoMuseRoutine.Run(at: Date(), ok: false, id: UUID().uuidString, status: "running")]
        let imported = try XCTUnwrap(backup([saved]).merging(into: []).routines.first)
        XCTAssertEqual(imported.runs.first?.status, "interrupted")
        XCTAssertNil(imported.runs.first?.finishedAt)
        XCTAssertNil(imported.runs.first?.duration)
    }

    func testLocalConflictKeepsExactConfigurationAndReportsLabel() throws {
        let local = row()
        var incoming = local
        incoming.prompt = "different instructions"
        incoming.revision = 99
        let result = try backup([incoming]).merging(into: [local])
        XCTAssertEqual(result.routines, [local])
        XCTAssertTrue(result.importedIDs.isEmpty)
        XCTAssertEqual(result.conflicts, [local.label])
    }

    func testDuplicateTaskAndFileIdentitiesAreRejected() throws {
        XCTAssertThrowsError(try backup([row(), row()]).merging(into: []))
        XCTAssertThrowsError(try backup([], paths: ["bin/task.sh", "bin/task.sh"]).validate())
    }

    func testUnsafePathsAreRejectedBeforeWriting() throws {
        for path in ["/outside", "../outside", "bin/../../outside", "bin\\outside", "C:/outside", "bin//task.sh", "bin/./task.sh", "bin/\0file", ".live-path"] {
            XCTAssertThrowsError(try backup([], paths: [path]).validate(), path)
        }
        XCTAssertNoThrow(try backup([], paths: ["bin/task.sh", "data/results.json", ".config/config.json"]).validate())
    }

    func testImportedTaskGetsFreshDedicatedConversationBinding() throws {
        var saved = row()
        saved.execution = NivoRoutineExecution()
        saved.dedicatedSessionID = UUID().uuidString
        saved.sessionId = saved.dedicatedSessionID
        let imported = try XCTUnwrap(backup([saved]).merging(into: []).routines.first)
        XCTAssertNil(imported.dedicatedSessionID)
        XCTAssertNil(imported.sessionId)
    }
}
