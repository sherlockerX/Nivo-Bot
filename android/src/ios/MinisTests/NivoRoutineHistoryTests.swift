import XCTest
@testable import Minis

/// 新运行详情保持旧历史可读，未知或中断状态不伪造成功。
final class NivoRoutineHistoryTests: XCTestCase {
    func testSuccessfulScriptRetainsDeliveryFailureWithoutBecomingExecutionFailure() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(timeIntervalSince1970: 100)
        let row = NanoMuseRoutine(label: "Script", prompt: "", hour: 9, minute: 0, createdAt: now,
            script: NivoRoutineScript(id: "daily.sh"))
        let started = NivoRoutineRunRules.starting(row, now: now, trigger: "manual")
        var run = try XCTUnwrap(started.runs.first)
        run.status = "completed"
        run.ok = true
        run.exitCode = 0
        run.verifiedOutcome = "success"
        run.finishedAt = now.addingTimeInterval(2)
        run.duration = 2
        run.result = "completed work"
        run.deliveryError = "database unavailable"
        let receipt = NivoRoutineSettlement(routineID: row.id, routineCreatedAt: row.createdAt, run: run)
        try NivoRoutineSettlementFiles.stage(receipt, directory: directory)
        let loaded = try XCTUnwrap(NivoRoutineSettlementFiles.read(directory: directory).first)
        let settled = try XCTUnwrap(loaded.applying(to: [started]).first)
        XCTAssertEqual(settled.runs.first?.deliveryError, "database unavailable")
        XCTAssertEqual(settled.runs.first?.verifiedOutcome, "success")
        XCTAssertEqual(settled.consecutiveFailures, 0)
        XCTAssertNil(settled.pendingRun)
        XCTAssertEqual(try loaded.applying(to: [settled]), [settled])
    }

    func testDebugFailureRetainsEvidenceWithoutCountingOrAutoDisabling() throws {
        var row = NanoMuseRoutine(label: "Script", prompt: "", hour: 9, minute: 0,
            execution: NivoRoutineExecution(autoDisableOnFailure: true, failureThreshold: 2))
        row.script = NivoRoutineScript(id: "daily.sh")
        row.debug = true
        row.consecutiveFailures = 1
        row.totalFailures = 3
        let started = NivoRoutineRunRules.starting(row, now: Date(), trigger: "manual")
        var result = try XCTUnwrap(started.runs.first)
        result.status = "failed"
        result.finishedAt = Date()
        result.duration = 1
        result.exitCode = 7
        result.verifiedOutcome = "failure"
        result.isDebug = true
        let receipt = NivoRoutineSettlement(routineID: row.id, routineCreatedAt: row.createdAt, run: result)
        let settled = try XCTUnwrap(receipt.applying(to: [started]).first)
        XCTAssertEqual(settled.runs.first?.exitCode, 7)
        XCTAssertEqual(settled.consecutiveFailures, 1)
        XCTAssertEqual(settled.totalFailures, 3)
        XCTAssertTrue(settled.enabled)
        XCTAssertEqual(NivoRoutineNotificationRules.decide(row: row, run: result, allRows: [settled],
            settings: NivoRoutineNotificationSettings(), now: Date(), dryNotify: false).reason, "debug")
    }

    func testStagedResultSettlesOnceAfterPrimaryArchiveFailure() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let date = Date(timeIntervalSince1970: 100)
        let row = NanoMuseRoutine(label: "Read", prompt: "Review", hour: 9, minute: 0, repeatMode: .once, createdAt: date)
        let started = NivoRoutineRunRules.starting(row, now: date, trigger: "manual")
        var completed = try XCTUnwrap(started.runs.first)
        completed.status = "failed"
        completed.finishedAt = date.addingTimeInterval(10)
        completed.duration = 10
        completed.result = "Partial result"
        let receipt = NivoRoutineSettlement(routineID: row.id, routineCreatedAt: row.createdAt, run: completed)
        try NivoRoutineSettlementFiles.stage(receipt, directory: directory)
        let loaded = try XCTUnwrap(NivoRoutineSettlementFiles.read(directory: directory).first)
        let interrupted = NivoRoutineRunRules.recovering([started])
        let settled = try loaded.applying(to: interrupted)
        XCTAssertEqual(settled.first?.runs.first?.result, "Partial result")
        XCTAssertEqual(settled.first?.totalFailures, 1)
        XCTAssertEqual(settled.first?.enabled, false)
        XCTAssertEqual(try loaded.applying(to: settled), settled)
        XCTAssertTrue(try loaded.applying(to: []).isEmpty)
        try NivoRoutineSettlementFiles.clear(loaded, directory: directory)
        XCTAssertTrue(try NivoRoutineSettlementFiles.read(directory: directory).isEmpty)
    }

    func testQueueHandoffKeepsIdentityAndDoesNotReplayInterruptedRun() throws {
        let row = NanoMuseRoutine(label: "Read", prompt: "Review", hour: 9, minute: 0)
        let queued = try NivoRoutineRunRules.enqueuing(row, now: Date(), dryNotify: true)
        let request = try XCTUnwrap(queued.pendingRun)
        XCTAssertThrowsError(try NivoRoutineRunRules.enqueuing(queued, now: Date(), dryNotify: false))
        let started = NivoRoutineRunRules.starting(queued, now: Date(), trigger: "active")
        XCTAssertNil(started.pendingRun)
        XCTAssertEqual(started.runs.first?.id, request.id)
        XCTAssertEqual(started.runs.first?.trigger, "command")
        XCTAssertThrowsError(try NivoRoutineRunRules.enqueuing(started, now: Date(), dryNotify: false))
        let recovered = try XCTUnwrap(NivoRoutineRunRules.recovering([started]).first)
        XCTAssertEqual(recovered.runs.first?.status, "interrupted")
        XCTAssertFalse(try XCTUnwrap(recovered.runs.first?.ok))
        XCTAssertNil(recovered.runs.first?.duration)
        XCTAssertNil(recovered.pendingRun)
    }

    func testResultPreviewBoundsMultibyteTextWithoutCorruptingIt() {
        let text = String(repeating: "焦点🧠", count: 30_000)
        let preview = NivoRoutineRunRules.boundedResult(text)
        XCTAssertTrue(preview.truncated)
        XCTAssertLessThanOrEqual(preview.text.utf8.count, NivoRoutineRunRules.maximumResultBytes)
        XCTAssertTrue(text.hasPrefix(preview.text))
        XCTAssertFalse(preview.text.contains("�"))
    }

    func testQueuedRequestSurvivesArchiveRoundTrip() throws {
        var row = NanoMuseRoutine(label: "Read", prompt: "Review", hour: 9, minute: 0)
        row.execution = NivoRoutineExecution()
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(row)) as? [String: Any])
        json["pendingRun"] = ["id": UUID().uuidString, "queuedAt": 100.0, "trigger": "command", "dryNotify": true]
        let decoded = try JSONDecoder().decode(NanoMuseRoutine.self, from: JSONSerialization.data(withJSONObject: json))
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any])
        XCTAssertNotNil(encoded["pendingRun"], "已接受的手动运行必须保存在任务档案中，不能重启后丢失")
    }

    func testLegacyRunDecodesWithoutInventedEvidence() throws {
        let data = Data(#"{"at":0,"ok":true,"note":"legacy"}"#.utf8)
        let run = try JSONDecoder().decode(NanoMuseRoutine.Run.self, from: data)
        XCTAssertTrue(run.ok)
        XCTAssertNil(run.sessionId)
        XCTAssertNil(run.duration)
        XCTAssertNil(run.result)
        XCTAssertNil(run.status)
    }

    func testRunDetailsRoundTrip() throws {
        let run = NanoMuseRoutine.Run(at: Date(timeIntervalSince1970: 100), ok: false, note: "timeout",
            id: "run", sessionId: "session", finishedAt: Date(timeIntervalSince1970: 110),
            duration: 10, trigger: "manual", result: "partial answer", status: "failed")
        XCTAssertEqual(try JSONDecoder().decode(NanoMuseRoutine.Run.self, from: JSONEncoder().encode(run)), run)
    }
}
