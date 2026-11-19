import XCTest
@testable import Minis

/// 查询拒绝写入、无效类型和不适用筛选，分页保留完整日记正文。
final class NivoPersonalRecordsQueryTests: XCTestCase {
    func testRejectsWritesPathsInvalidNumbersAndIrrelevantFilters() {
        let invalid: [[String: Any]] = [
            ["kind": "delete"], ["path": "/private"], ["kind": "coach", "startDate": "2026-01-01"],
            ["limit": true], ["offset": -1], ["limit": "4"], ["limit": 31],
            ["kind": "coach", "section": "overview", "targetId": "one"]
        ]
        for args in invalid { XCTAssertThrowsError(try NivoPersonalRecordsRequest.parse(args)) }
    }

    func testWholeDayPaginationAndStrictCalendarValidation() throws {
        let request = try NivoPersonalRecordsRequest.parse(["kind": "reflections", "startDate": "2026-01-01",
            "endDate": "2026-01-04", "limit": 2, "offset": 2])
        let query = try request.mosaicQuery()
        XCTAssertEqual(NivoJigsawQuery.date(query.pageStart), "2026-01-03")
        XCTAssertNil(query.nextOffset)
        XCTAssertThrowsError(try NivoPersonalRecordsRequest.parse(["kind": "reflections", "startDate": "2026-02-30"]).mosaicQuery())
    }

    func testCoachPaginationAndMissingDetailAreExplicit() throws {
        let request = try NivoPersonalRecordsRequest.parse(["kind": "coach", "section": "topics", "limit": 1])
        let output = try NivoPersonalRecordsOutput.coach(request, state: NivoCoachState())
        XCTAssertTrue(output.contains("\"total\":0"))
        XCTAssertTrue(output.contains("\"status\":\"empty\""))
        let detail = try NivoPersonalRecordsRequest.parse(["kind": "coach", "section": "topics", "targetId": "missing"])
        XCTAssertThrowsError(try NivoPersonalRecordsOutput.coach(detail, state: NivoCoachState()))
    }

    func testCoachListsBoundedSummariesAndExactDetailRetainsFullText() throws {
        var state = NivoCoachState()
        let text = String(repeating: "用户原话", count: 8_000)
        state.topics = (0..<3).map { NivoCoachTopic(id: "topic\($0)", courseID: "course", unitID: "unit", title: "Topic", caseText: text) }
        let request = try NivoPersonalRecordsRequest.parse(["kind": "coach", "section": "topics", "limit": 1, "offset": 1])
        let output = try NivoPersonalRecordsOutput.coach(request, state: state)
        XCTAssertTrue(output.contains("\"nextOffset\":2"))
        XCTAssertFalse(output.contains(text))
        let detail = try NivoPersonalRecordsRequest.parse(["kind": "coach", "section": "topics", "targetId": "topic1"])
        XCTAssertTrue(try NivoPersonalRecordsOutput.coach(detail, state: state).contains(text))
    }

    func testFocusDateRangeExcludesOlderDeletedAndFutureRows() throws {
        var rows: [NivoFocusSession] = []
        for index in 0..<5 {
            var session = try NivoFocusRules.start(owner: "local", id: "focus\(index)", title: "Read", task: nil,
                mode: .pomodoro, minutes: 3,
                clock: NivoFocusClockSample(wallMs: Int64(index) * 86_400_000, elapsedMs: 0, bootID: "boot"))
            session.status = .finished
            if index == 2 { session.deletedAt = 1 }
            rows.append(session)
        }
        let selected = try NivoPersonalRecordsFocusQuery.rows(rows, kind: "sessions", startDay: 1, endDay: 3,
            timeZone: TimeZone(secondsFromGMT: 0)!)
        XCTAssertEqual(selected.map(\.id), ["focus3", "focus1"])
        XCTAssertThrowsError(try NivoPersonalRecordsFocusQuery.rows(rows, kind: "sessions", startDay: 3, endDay: 1))
    }

    func testFocusStatisticsIncludesAllGroupsWithinLocalDayBoundaries() throws {
        let chicago = try XCTUnwrap(TimeZone(identifier: "America/Chicago"))
        let formatter = ISO8601DateFormatter()
        let from = Int64(try XCTUnwrap(formatter.date(from: "2026-03-08T06:00:00Z")).timeIntervalSince1970 * 1_000)
        let until = Int64(try XCTUnwrap(formatter.date(from: "2026-03-09T05:00:00Z")).timeIntervalSince1970 * 1_000)
        let requestedDay = try NivoJigsawQuery.day("2026-03-08")
        var sessions: [NivoFocusSession] = []
        var spans: [NivoFocusSpan] = []
        for index in 0..<53 {
            let id = "focus\(index)"
            let startedAt = index == 0 ? from - 500 : until - 500
            var session = try NivoFocusRules.start(owner: "one", id: id, title: "Focus", task: nil,
                mode: index == 52 ? .rest : .pomodoro, minutes: 3,
                clock: NivoFocusClockSample(wallMs: startedAt, elapsedMs: 0, bootID: "boot"))
            session.status = index == 51 ? .paused : .finished
            session.groupName = "Group \(index)"
            sessions.append(session)
            spans.append(.init(id: "span\(index)", sessionId: id, startedAt: startedAt, durationMs: 1_000))
        }
        let statistics = try NivoPersonalRecordsFocusQuery.statistics(sessions, spans: spans, tasks: [],
            startDay: requestedDay, endDay: requestedDay, timeZone: chicago)
        XCTAssertEqual(statistics.totalMs, 25_500)
        XCTAssertEqual(statistics.groups.count, 51)
        XCTAssertTrue(statistics.groups.allSatisfy { $0.durationMs == 500 })
        XCTAssertTrue(statistics.groups.contains { $0.group == "Group 0" })
        XCTAssertThrowsError(try NivoPersonalRecordsFocusQuery.statistics(sessions, spans: spans, tasks: [],
            startDay: requestedDay, endDay: requestedDay + 3_661, timeZone: chicago))
    }

    func testDefaultDatesFollowLocalDayAcrossInternationalDateBoundary() throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-16T02:00:00Z"))
        let chicago = try XCTUnwrap(TimeZone(identifier: "America/Chicago"))
        let request = try NivoPersonalRecordsRequest.parse(["kind": "reflections"])
        let local = try request.mosaicQuery(now: now, timeZone: chicago)
        XCTAssertEqual(NivoJigsawQuery.date(local.endDay), "2026-11-15")
        XCTAssertEqual(local.today, NivoLifeDay.value(now, timeZone: chicago))
        let legacy = try NivoJigsawQuery.parse(["list"], now: now)
        XCTAssertEqual(NivoJigsawQuery.date(legacy.endDay), "2026-11-16")
        let output = try NivoJigsawOutput.render(query: local, state: NivoMosaicState(ownerKey: "one"))
        // 不依赖JSON对斜杠的转义格式，验证调用方实际解码得到的时区。
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        XCTAssertEqual(decoded["timezone"] as? String, "America/Chicago")
        let queried = try XCTUnwrap(decoded["queried"] as? [String: Any])
        XCTAssertEqual(queried["timezone"] as? String, "America/Chicago")
        XCTAssertTrue(try NivoPersonalRecordsOutput.reflectionRange(.init(ownerKey: "one"), timeZone: chicago).contains("saved_local_calendar_day"))
    }

    func testReflectionLinksPreserveSavedMeaningWithoutPhotosOrDrafts() throws {
        var state = NivoMosaicState(ownerKey: "one")
        var entry = NivoMosaicEntry(ownerKey: "one", id: "entry", day: 1, text: "Saved reflection",
            taskIDs: ["task"], focusIDs: ["focus"], createdAt: 1, updatedAt: 2)
        entry.taskSnapshots = [.init(id: "task", title: "Original task title", status: .todo)]
        entry.focusSnapshots = [.init(id: "focus", title: "Focus title", elapsedMs: 60_000)]
        entry.reflectionSessionID = "focus"
        entry.mediaPath = "private-photo.jpg"
        state.entries = [entry]
        state.drafts = [.init(ownerKey: "one", id: "draft", day: 1, text: "Unsaved secret", updatedAt: 3)]
        let query = try NivoJigsawQuery.parse(["get", "--date", "1970-01-02"])
        let output = try NivoJigsawOutput.render(query: query, state: state)
        XCTAssertTrue(output.contains("reflectionSessionID"))
        XCTAssertTrue(output.contains("Original task title"))
        XCTAssertTrue(output.contains("saved_snapshot_not_current_completion_proof"))
        XCTAssertFalse(output.contains("private-photo.jpg"))
        XCTAssertFalse(output.contains("Unsaved secret"))
    }

    func testReflectionJSONKeepsActualLinkTimesAndLeavesLegacyTimesNull() throws {
        var state = NivoMosaicState(ownerKey: "one")
        var entry = NivoMosaicEntry(ownerKey: "one", id: "timed", day: 1, text: "With measured time",
            taskIDs: ["task"], focusIDs: ["focus", "legacy"], createdAt: 900, updatedAt: 901)
        entry.taskSnapshots = [.init(id: "task", title: "Saved task", status: .inProgress, linkedAt: 800)]
        entry.focusSnapshots = [.init(id: "focus", title: "Timed focus", elapsedMs: 600,
            startedAt: 100, endedAt: 700), .init(id: "legacy", title: "Old focus", elapsedMs: 200)]
        state.entries = [entry]
        let query = try NivoJigsawQuery.parse(["get", "--date", "1970-01-02"])
        let output = try NivoJigsawOutput.render(query: query, state: state)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        let day = try XCTUnwrap((root["days"] as? [[String: Any]])?.first)
        let saved = try XCTUnwrap((day["records"] as? [[String: Any]])?.first)
        let tasks = try XCTUnwrap(saved["taskSnapshots"] as? [[String: Any]])
        let sessions = try XCTUnwrap(saved["focusSnapshots"] as? [[String: Any]])
        XCTAssertEqual((tasks.first?["linkedAt"] as? NSNumber)?.int64Value, 800)
        XCTAssertEqual((sessions.first?["startedAt"] as? NSNumber)?.int64Value, 100)
        XCTAssertEqual((sessions.first?["endedAt"] as? NSNumber)?.int64Value, 700)
        XCTAssertTrue(sessions.last?["startedAt"] is NSNull)
        XCTAssertTrue(sessions.last?["endedAt"] is NSNull)
    }

    func testReflectionQuerySeparatesMeasuredDurationFromSaveTime() throws {
        var state = NivoMosaicState(ownerKey: "one")
        let note = NivoMosaicEntry(ownerKey: "one", id: "note", day: 1, text: "Daily note",
            taskIDs: [], focusIDs: [], createdAt: 900, updatedAt: 900)
        var timed = NivoMosaicEntry(ownerKey: "one", id: "timed", day: 1, text: "Measured work",
            taskIDs: [], focusIDs: ["first", "second"], createdAt: 900, updatedAt: 900)
        timed.focusSnapshots = [.init(id: "first", title: "First", elapsedMs: 600, startedAt: 100, endedAt: 800),
            .init(id: "second", title: "Second", elapsedMs: 200),
            .init(id: "first", title: "Duplicate", elapsedMs: 600)]
        let legacy = NivoMosaicEntry(ownerKey: "one", id: "legacy", day: 1, text: "Missing snapshot",
            taskIDs: [], focusIDs: ["unknown"], createdAt: 900, updatedAt: 900)
        state.entries = [note, timed, legacy]

        let query = try NivoJigsawQuery.parse(["get", "--date", "1970-01-02"])
        let output = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(NivoJigsawOutput.render(query: query, state: state).utf8)) as? [String: Any])
        let day = try XCTUnwrap((output["days"] as? [[String: Any]])?.first)
        let records = try XCTUnwrap(day["records"] as? [[String: Any]])
        let noteData = try XCTUnwrap(records.first { $0["id"] as? String == "note" })
        let timedData = try XCTUnwrap(records.first { $0["id"] as? String == "timed" })
        let legacyData = try XCTUnwrap(records.first { $0["id"] as? String == "legacy" })
        XCTAssertEqual(noteData["kind"] as? String, "daily_note")
        XCTAssertEqual(noteData["measured_focus_ms"] as? Int, 0)
        XCTAssertEqual(timedData["kind"] as? String, "focused_activity")
        XCTAssertEqual(timedData["measured_focus_ms"] as? Int, 800)
        XCTAssertEqual(timedData["created_at_ms"] as? Int, 900)
        XCTAssertEqual(legacyData["kind"] as? String, "focused_activity")
        XCTAssertTrue(legacyData["measured_focus_ms"] is NSNull)
        XCTAssertEqual(day["measured_focus_ms"] as? Int, 800)
        XCTAssertEqual(day["records_with_unknown_focus_duration"] as? Int, 1)

        let statistics = try NivoJigsawQuery.parse(["stats", "--start", "1970-01-01", "--end", "1970-01-02"])
        let statsRoot = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(NivoJigsawOutput.render(query: statistics, state: state).utf8)) as? [String: Any])
        let totals = try XCTUnwrap(statsRoot["stats"] as? [String: Any])
        XCTAssertEqual(totals["measured_focus_ms"] as? Int, 800)
        XCTAssertEqual(totals["focused_records"] as? Int, 2)
        XCTAssertEqual(totals["records_with_unknown_focus_duration"] as? Int, 1)
    }

    func testMarkdownKeepsEachReflectionWithItsOwnTaskAndFocusEvidence() throws {
        var state = NivoMosaicState(ownerKey: "one")
        var first = NivoMosaicEntry(ownerKey: "one", id: "first", day: 1, text: "First reflection",
            taskIDs: ["task-a"], focusIDs: ["focus-a"], createdAt: 1, updatedAt: 1)
        first.reflectionSessionID = "focus-a"
        first.taskSnapshots = [.init(id: "task-a", title: "Saved title", status: .todo, linkedAt: 100)]
        first.focusSnapshots = [.init(id: "focus-a", title: "Morning", elapsedMs: 30,
            startedAt: 10, endedAt: 40)]
        var second = NivoMosaicEntry(ownerKey: "one", id: "second", day: 1, text: "Second reflection",
            taskIDs: [], focusIDs: ["focus-b"], createdAt: 2, updatedAt: 2)
        second.focusSnapshots = [.init(id: "focus-b", title: "Legacy", elapsedMs: 25)]
        state.entries = [first, second]
        let query = try NivoJigsawQuery.parse(["get", "--date", "1970-01-02", "--format", "md"])
        let output = try NivoJigsawOutput.render(query: query, state: state)
        let sections = output.components(separatedBy: "### Record ")
        XCTAssertEqual(sections.count, 3)
        XCTAssertTrue(sections[1].contains("First reflection"))
        XCTAssertTrue(sections[1].contains("Time spent (measured focus): 30 ms"))
        XCTAssertTrue(sections[1].contains("Saved task task-a: Saved title; status=todo; linkedAt=100"))
        XCTAssertTrue(sections[1].contains("elapsedMs=30; startedAt=10; endedAt=40"))
        XCTAssertTrue(sections[1].contains("Reflection source: focus-a"))
        XCTAssertFalse(sections[1].contains("focus-b"))
        XCTAssertTrue(sections[2].contains("Second reflection"))
        XCTAssertTrue(sections[2].contains("startedAt=unknown; endedAt=unknown"))
        XCTAssertFalse(sections[2].contains("task-a"))
    }
}
