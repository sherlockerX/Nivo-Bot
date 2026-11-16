import XCTest
@testable import Minis

/// 日期分页和隐私输出直接测试生产解析器，不用镜像实现替代。
final class NivoJigsawQueryTests: XCTestCase {
    func testStrictDatesUnknownCommandsAndDuplicateOptions() throws {
        for args in [["delete"], ["list", "--start", "2026-02-30"], ["get"],
                     ["list", "--days", "0"], ["list", "--days", "367"],
                     ["list", "--start", "2026-11-13", "--from", "2026-11-12"],
                     ["export", "--output", "/tmp/data"], ["get", "--date", "2026-1-01"]] {
            XCTAssertThrowsError(try NivoJigsawQuery.parse(args), "必须拒绝：\(args)")
        }
        XCTAssertEqual(try NivoJigsawQuery.day("1970-01-01"), 0)
        XCTAssertEqual(try NivoJigsawQuery.day("1969-12-31"), -1)
        XCTAssertEqual(try NivoJigsawQuery.date(NivoJigsawQuery.day("2024-02-29")), "2024-02-29")
    }

    func testPaginationNeverSplitsOneDayAndPreservesWholeText() throws {
        let query = try NivoJigsawQuery.parse(["list", "--start", "1970-01-01", "--end", "1970-01-04", "--limit", "1", "--offset", "1"])
        var state = NivoMosaicState(ownerKey: "local")
        state.entries = [entry(id: "a", day: 1, text: "One\nTwo"), entry(id: "b", day: 1, text: "Second record"), entry(id: "c", day: 2, text: "Next day")]
        let result = try object(NivoJigsawOutput.render(query: query, state: state))
        let days = try XCTUnwrap(result["days"] as? [[String: Any]])
        XCTAssertEqual(days.count, 1)
        XCTAssertEqual(days.first?["date"] as? String, "1970-01-02")
        XCTAssertEqual(days.first?["text"] as? String, "One\nTwo\nSecond record")
        XCTAssertEqual((days.first?["records"] as? [[String: Any]])?.count, 2)
        XCTAssertEqual(result["next_offset"] as? Int, 2)
    }

    func testOutputExcludesDraftsDeletedRecordsAndPhotoPaths() throws {
        let query = try NivoJigsawQuery.parse(["get", "--date", "1970-01-02"])
        var state = NivoMosaicState(ownerKey: "private-account")
        var saved = entry(id: "a", day: 1, text: "Visible note")
        saved.mediaPath = "11111111-1111-1111-1111-111111111111.jpg"
        var deleted = entry(id: "b", day: 1, text: "Deleted secret")
        deleted.deletedAt = 100
        state.entries = [saved, deleted]
        state.drafts = [NivoMosaicDraft(ownerKey: "private-account", id: "draft", day: 1, text: "Draft secret", updatedAt: 100)]
        let rendered = try NivoJigsawOutput.render(query: query, state: state)
        XCTAssertTrue(rendered.contains("Visible note"))
        XCTAssertFalse(rendered.contains("Deleted secret"))
        XCTAssertFalse(rendered.contains("Draft secret"))
        XCTAssertFalse(rendered.contains("11111111"))
        XCTAssertFalse(rendered.contains("private-account"))
        XCTAssertTrue(rendered.contains("has_photo"))
    }

    func testExplicitlyClearedDayMoodDoesNotReappearFromOldRecord() throws {
        let query = try NivoJigsawQuery.parse(["get", "--date", "1970-01-02"])
        var state = NivoMosaicState(ownerKey: "local")
        var row = entry(id: "a", day: 1, text: "Note")
        row.mood = .great
        state.entries = [row]
        state.days = [NivoMosaicDayInfo(day: 1, mood: nil, updatedAt: 100)]
        let result = try object(NivoJigsawOutput.render(query: query, state: state))
        let days = try XCTUnwrap(result["days"] as? [[String: Any]])
        XCTAssertTrue(days.first?["mood"] is NSNull)
    }

    func testStatisticsRejectOversizedHabitPlanWithoutBuildingEveryRecord() throws {
        let query = try NivoJigsawQuery.parse(["stats", "--start", "1970-01-01", "--end", "1970-12-31"])
        var state = NivoMosaicState(ownerKey: "local")
        state.habits = (0..<30).map { index in
            NivoMosaicHabit(ownerKey: "local", id: "habit-\(index)", title: "Read", weekdays: Set(1...7), createdAt: -86_400_000)
        }
        XCTAssertThrowsError(try NivoJigsawOutput.render(query: query, state: state))
    }

    func testBareOptionIsRejectedWithoutIndexingEmptySplit() {
        XCTAssertThrowsError(try NivoJigsawQuery.parse(["list", "--", "value"]))
    }

    private func entry(id: String, day: Int64, text: String) -> NivoMosaicEntry {
        NivoMosaicEntry(ownerKey: "local", id: id, day: day, text: text, taskIDs: [], focusIDs: [], createdAt: 1, updatedAt: 1)
    }

    private func object(_ string: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(string.utf8)) as? [String: Any])
    }
}
