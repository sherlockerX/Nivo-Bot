import XCTest
@testable import Minis

/// 使用临时档案验证生产查询，不启动真实账户、调度器或任何模型请求。
final class NivoPersonalRecordsPlanningQueryTests: XCTestCase {
    func testPlanningRequestsAcceptExactIDsAndRejectUnrelatedFilters() throws {
        for kind in ["goals", "routines"] {
            let request = try NivoPersonalRecordsRequest.parse(["kind": kind, "targetId": "record-1"])
            XCTAssertEqual(request.targetID, "record-1")
            XCTAssertThrowsError(try NivoPersonalRecordsRequest.parse(["kind": kind, "section": "overview"]))
            XCTAssertThrowsError(try NivoPersonalRecordsRequest.parse(["kind": kind, "startDate": "2026-01-01"]))
            XCTAssertThrowsError(try NivoPersonalRecordsRequest.parse(["kind": kind, "targetId": "../secret"]))
            XCTAssertThrowsError(try NivoPersonalRecordsRequest.parse(["kind": kind, "action": "run"]))
        }
    }

    func testGoalPaginationIsStableAndDetailKeepsWholeSavedText() throws {
        let directory = try temporaryDirectory()
        let text = String(repeating: "保存的目标原文", count: 4_000)
        try writeGoals([goal("b", note: text), goal("a", note: text), goal("older", created: "2026-01-01T00:00:00Z")], to: directory)
        let rows = try NivoPersonalRecordsPlanningQuery.readGoals(directory: directory)
        let request = try NivoPersonalRecordsRequest.parse(["kind": "goals", "limit": 1, "offset": 1])
        let output = try NivoPersonalRecordsPlanningQuery.goals(request, rows: rows)
        let page = try data(output)
        XCTAssertEqual((page["items"] as? [[String: Any]])?.first?["id"] as? String, "b")
        XCTAssertEqual(page["nextOffset"] as? Int, 2)
        XCTAssertFalse(output.contains(text))
        let detail = try NivoPersonalRecordsRequest.parse(["kind": "goals", "targetId": "a"])
        let saved = try data(NivoPersonalRecordsPlanningQuery.goals(detail, rows: rows))
        XCTAssertEqual(saved["lastNote"] as? String, text)
        XCTAssertEqual((saved["steps"] as? [[String: Any]])?.first?["text"] as? String, "First step")
        XCTAssertEqual(saved["why"] as? String, "Saved motivation")
        XCTAssertEqual(saved["createdAt"] as? Int64, 1_767_312_000_000)
        XCTAssertTrue(saved["lastCheckedAt"] is NSNull)
    }

    func testMissingAndCorruptArchivesAreDifferentAndReadsDoNotUseCache() throws {
        let directory = try temporaryDirectory()
        XCTAssertTrue(try NivoPersonalRecordsPlanningQuery.readGoals(directory: directory).isEmpty)
        XCTAssertTrue(try NivoPersonalRecordsPlanningQuery.readRoutines(directory: directory).isEmpty)
        try writeGoals([goal("first")], to: directory)
        XCTAssertEqual(try NivoPersonalRecordsPlanningQuery.readGoals(directory: directory).first?.id, "first")
        try writeGoals([goal("second")], to: directory)
        XCTAssertEqual(try NivoPersonalRecordsPlanningQuery.readGoals(directory: directory).first?.id, "second")
        for filename in ["goals.json", "routines.json"] {
            let file = directory.appendingPathComponent(filename)
            try Data("broken JSON".utf8).write(to: file)
        }
        XCTAssertThrowsError(try NivoPersonalRecordsPlanningQuery.readGoals(directory: directory))
        XCTAssertThrowsError(try NivoPersonalRecordsPlanningQuery.readRoutines(directory: directory))
    }

    func testDuplicateIDsAndDirectoriesAreRejected() throws {
        let directory = try temporaryDirectory()
        try writeGoals([goal("same"), goal("same")], to: directory)
        XCTAssertThrowsError(try NivoPersonalRecordsPlanningQuery.readGoals(directory: directory))
        let routineFile = directory.appendingPathComponent("routines.json")
        try FileManager.default.createDirectory(at: routineFile, withIntermediateDirectories: false)
        XCTAssertThrowsError(try NivoPersonalRecordsPlanningQuery.readRoutines(directory: directory))
    }

    func testRoutineDetailPaginatesRetainedRunsWithoutTruncatingSavedPromptOrResult() throws {
        let directory = try temporaryDirectory()
        let prompt = String(repeating: "原始提示词", count: 4_000)
        let result = String(repeating: "保存的执行结果", count: 4_000)
        var row = NanoMuseRoutine(id: "routine", label: "Review", prompt: prompt, hour: 9, minute: 0)
        row.runs = [
            .init(at: Date(timeIntervalSince1970: 20), ok: true, id: "new", result: "Recent", status: "completed"),
            .init(at: Date(timeIntervalSince1970: 10), ok: false, note: "Saved note", id: "old", result: result,
                  status: "interrupted", resultTruncated: true)
        ]
        let file = directory.appendingPathComponent("routines.json")
        try NivoRoutineArchive.write([row], to: file)
        let before = try Data(contentsOf: file)
        let rows = try NivoPersonalRecordsPlanningQuery.readRoutines(directory: directory)
        let list = try NivoPersonalRecordsRequest.parse(["kind": "routines", "limit": 1])
        XCTAssertFalse(try NivoPersonalRecordsPlanningQuery.routines(list, rows: rows).contains(prompt))
        let request = try NivoPersonalRecordsRequest.parse(["kind": "routines", "targetId": row.id, "limit": 1, "offset": 1])
        let detail = try data(NivoPersonalRecordsPlanningQuery.routines(request, rows: rows))
        XCTAssertEqual(detail["prompt"] as? String, prompt)
        XCTAssertEqual(detail["historyScope"] as? String, "retained_on_device")
        let page = try XCTUnwrap(detail["runs"] as? [String: Any])
        let saved = try XCTUnwrap((page["items"] as? [[String: Any]])?.first)
        XCTAssertEqual(saved["id"] as? String, "old")
        XCTAssertEqual(saved["result"] as? String, result)
        XCTAssertEqual(saved["resultTruncated"] as? Bool, true)
        XCTAssertTrue(page["nextOffset"] is NSNull)
        XCTAssertTrue(saved["finishedAt"] is NSNull)
        XCTAssertEqual(try Data(contentsOf: file), before)
    }

    func testRoutineOrderingAndOutOfRangePageKeepStableTotals() throws {
        let now = Date(timeIntervalSince1970: 100)
        let rows = ["b", "a"].map { NanoMuseRoutine(id: $0, label: $0, prompt: "Saved", hour: 9, minute: 0, createdAt: now) }
        let first = try NivoPersonalRecordsRequest.parse(["kind": "routines", "limit": 1])
        let page = try data(NivoPersonalRecordsPlanningQuery.routines(first, rows: rows))
        XCTAssertEqual((page["items"] as? [[String: Any]])?.first?["id"] as? String, "a")
        let pastEnd = try NivoPersonalRecordsRequest.parse(["kind": "routines", "offset": 100])
        let emptyPage = try data(NivoPersonalRecordsPlanningQuery.routines(pastEnd, rows: rows))
        XCTAssertEqual(emptyPage["total"] as? Int, 2)
        XCTAssertEqual((emptyPage["items"] as? [[String: Any]])?.count, 0)
        XCTAssertEqual(emptyPage["status"] as? String, "ok")
        XCTAssertTrue(emptyPage["nextOffset"] is NSNull)
    }

    func testZeroDurationAndEpochRemainRealValuesInsteadOfMissingEvidence() throws {
        let zero = Date(timeIntervalSince1970: 0)
        var row = NanoMuseRoutine(id: "zero", label: "Immediate", prompt: "Saved", hour: 9, minute: 0, createdAt: zero)
        row.runs = [.init(at: zero, ok: true, finishedAt: zero, duration: 0, status: "completed", exitCode: 0)]
        let request = try NivoPersonalRecordsRequest.parse(["kind": "routines", "targetId": row.id])
        let detail = try data(NivoPersonalRecordsPlanningQuery.routines(request, rows: [row]))
        XCTAssertEqual(detail["createdAt"] as? Int, 0)
        let page = try XCTUnwrap(detail["runs"] as? [String: Any])
        let saved = try XCTUnwrap((page["items"] as? [[String: Any]])?.first)
        XCTAssertEqual(saved["at"] as? Int, 0)
        XCTAssertEqual(saved["finishedAt"] as? Int, 0)
        XCTAssertEqual(saved["durationSeconds"] as? Double, 0)
        XCTAssertEqual(saved["exitCode"] as? Int, 0)
    }

    func testPromptSelfReportWithoutScriptEvidenceKeepsCompleteSavedNoteAndResult() throws {
        let directory = try temporaryDirectory()
        let note = "模型任务保存的说明\n包含完整第二行。"
        let result = String(repeating: "模型自报结果保持完整。\n", count: 2_000)
        var row = NanoMuseRoutine(id: "prompt-report", label: "Prompt report", prompt: "Review saved records", hour: 9, minute: 0)
        row.runs = [.init(at: Date(timeIntervalSince1970: 10), ok: true, note: note, id: "run",
            result: result, status: "completed", reportedStatus: "completed", resultSource: "self_report")]
        try NivoRoutineArchive.write([row], to: directory.appendingPathComponent("routines.json"))
        let rows = try NivoPersonalRecordsPlanningQuery.readRoutines(directory: directory)
        let request = try NivoPersonalRecordsRequest.parse(["kind": "routines", "targetId": row.id])
        let detail = try data(NivoPersonalRecordsPlanningQuery.routines(request, rows: rows))
        let page = try XCTUnwrap(detail["runs"] as? [String: Any])
        let saved = try XCTUnwrap((page["items"] as? [[String: Any]])?.first)
        XCTAssertEqual(saved["note"] as? String, note)
        XCTAssertEqual(saved["result"] as? String, result)
        XCTAssertTrue(saved["contentOmitted"] is NSNull)
    }

    func testScriptConfigurationAndOutputNeverEnterPersonalResultsEvenAfterEditingRoutine() throws {
        let secret = "SCRIPT_CREDENTIAL_SENTINEL"
        var row = NanoMuseRoutine(id: "script", label: "Script", prompt: "", hour: 9, minute: 0,
            script: NivoRoutineScript(id: "private.sh", arguments: [secret]))
        row.runs = [.init(at: Date(timeIntervalSince1970: 10), ok: false, note: secret, result: secret,
            status: "failed", exitCode: 1, resultSource: "script_stdout", scriptDigest: "digest",
            stdoutBytes: 1, stdoutPreview: secret, deliveryError: secret)]
        let request = try NivoPersonalRecordsRequest.parse(["kind": "routines", "targetId": row.id])
        for isScript in [true, false] {
            if !isScript { row.script = nil; row.prompt = "New prompt" }
            let output = try NivoPersonalRecordsPlanningQuery.routines(request, rows: [row])
            XCTAssertFalse(output.contains(secret))
            XCTAssertFalse(output.contains("private.sh"))
            XCTAssertFalse(output.contains("stdoutPreview"))
            XCTAssertTrue(output.contains("script_execution_content"))
            let detail = try data(output)
            let page = try XCTUnwrap(detail["runs"] as? [String: Any])
            let saved = try XCTUnwrap((page["items"] as? [[String: Any]])?.first)
            XCTAssertEqual(saved["exitCode"] as? Int, 1)
            XCTAssertTrue(saved["result"] is NSNull)
        }
    }

    func testReadingRunningArchiveDoesNotRecoverOrSettleOrChangeConfiguration() throws {
        let directory = try temporaryDirectory()
        let now = Date(timeIntervalSince1970: 100)
        let routine = NanoMuseRoutine(id: "routine", label: "Once", prompt: "Review", hour: 9, minute: 0,
            repeatMode: .once, createdAt: now)
        let started = NivoRoutineRunRules.starting(routine, now: now, trigger: "manual")
        var finished = try XCTUnwrap(started.runs.first)
        finished.status = "completed"
        finished.ok = true
        finished.finishedAt = now.addingTimeInterval(1)
        finished.duration = 1
        finished.result = "Uncommitted result"
        let settlements = directory.appendingPathComponent("routine-settlements")
        try NivoRoutineSettlementFiles.stage(.init(routineID: routine.id, routineCreatedAt: now, run: finished), directory: settlements)
        let file = directory.appendingPathComponent("routines.json")
        try NivoRoutineArchive.write([started], to: file)
        let before = try Data(contentsOf: file)
        let rows = try NivoPersonalRecordsPlanningQuery.readRoutines(directory: directory)
        XCTAssertEqual(rows, [started])
        XCTAssertEqual(rows.first?.runs.first?.status, "running")
        XCTAssertEqual(rows.first?.enabled, true)
        let request = try NivoPersonalRecordsRequest.parse(["kind": "routines", "targetId": routine.id])
        let output = try NivoPersonalRecordsPlanningQuery.routines(request, rows: rows)
        XCTAssertFalse(output.contains("Uncommitted result"))
        XCTAssertEqual(try data(output)["unappliedSettlementReceiptsIncluded"] as? Bool, false)
        XCTAssertEqual(try Data(contentsOf: file), before)
        XCTAssertEqual(try NivoRoutineSettlementFiles.read(directory: settlements).count, 1)
    }

    func testMissingTargetsAndOversizedOutputFailExplicitly() throws {
        for kind in ["goals", "routines"] {
            let request = try NivoPersonalRecordsRequest.parse(["kind": kind, "targetId": "missing"])
            if kind == "goals" { XCTAssertThrowsError(try NivoPersonalRecordsPlanningQuery.goals(request, rows: [])) }
            else { XCTAssertThrowsError(try NivoPersonalRecordsPlanningQuery.routines(request, rows: [])) }
        }
        let directory = try temporaryDirectory()
        try writeGoals([goal("large", note: String(repeating: "x", count: 2 * 1_024 * 1_024))], to: directory)
        let rows = try NivoPersonalRecordsPlanningQuery.readGoals(directory: directory)
        let request = try NivoPersonalRecordsRequest.parse(["kind": "goals", "targetId": "large"])
        XCTAssertThrowsError(try NivoPersonalRecordsPlanningQuery.goals(request, rows: rows))
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("planning-query-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func goal(_ id: String, note: String = "Saved note", created: String = "2026-01-02T00:00:00Z") -> [String: Any] {
        ["id": id, "title": "Goal " + id, "why": "Saved motivation", "category": "health",
         "checkEveryHours": 0, "checkHour": 9, "checkMinute": 0, "progress": 25, "status": "active",
         "steps": [["id": "step", "text": "First step", "done": false]], "lastNote": note,
         "createdAt": created, "updatedAt": created]
    }

    private func writeGoals(_ goals: [[String: Any]], to directory: URL) throws {
        try JSONSerialization.data(withJSONObject: goals).write(to: directory.appendingPathComponent("goals.json"))
    }

    private func data(_ output: String) throws -> [String: Any] {
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        XCTAssertEqual(root["success"] as? Bool, true)
        return try XCTUnwrap(root["data"] as? [String: Any])
    }
}
