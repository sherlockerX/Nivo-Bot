import XCTest
@testable import Minis

/// 对真实CLI解析和原生工具参数复用入口验证日期、分页及紧凑输出协议。
final class NivoJigsawProtocolTests: XCTestCase {
    func testCompactIsAFlagAndPreservesPaginationAndText() throws {
        let arguments = ["export", "--start", "1970-01-01", "--end", "1970-01-03", "--limit", "1"]
        let plain = try NivoJigsawQuery.parse(arguments)
        let compact = try NivoJigsawQuery.parse(arguments + ["--compact"])
        var state = NivoMosaicState(ownerKey: "isolated-test")
        state.entries = [.init(ownerKey: "isolated-test", id: "example", day: 0, text: "Saved note\n第二行",
            taskIDs: [], focusIDs: [], createdAt: 1, updatedAt: 1)]
        let now = Date(timeIntervalSince1970: 0)
        let prettyOutput = try NivoJigsawOutput.render(query: plain, state: state, now: now)
        let compactOutput = try NivoJigsawOutput.render(query: compact, state: state, now: now)
        XCTAssertEqual(try object(prettyOutput) as NSDictionary, try object(compactOutput) as NSDictionary)
        XCTAssertFalse(compactOutput.contains("\n"))
        let days = try XCTUnwrap(object(compactOutput)["days"] as? [[String: Any]])
        XCTAssertEqual(days.first?["text"] as? String, "Saved note\n第二行")
        XCTAssertEqual(try object(compactOutput)["next_offset"] as? Int, 1)
        XCTAssertThrowsError(try NivoJigsawQuery.parse(arguments + ["--compact", "--compact"]))
        XCTAssertThrowsError(try NivoJigsawQuery.parse(arguments + ["--compact=false"]))
        XCTAssertThrowsError(try NivoJigsawQuery.parse(arguments + ["--compact", "--format", "md"]))
    }

    func testDefaultTimezoneMatchesCurrentDeviceAndExplicitTimezoneStaysDeterministic() throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-16T02:00:00Z"))
        let local = try NivoJigsawQuery.parse(["list"], now: now)
        XCTAssertEqual(local.zoneID, TimeZone.current.identifier)
        XCTAssertEqual(local.today, NivoLifeDay.value(now, timeZone: .current))
        let losAngeles = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let cli = try NivoJigsawQuery.parse(["list"], now: now, timeZone: losAngeles)
        let request = try NivoPersonalRecordsRequest.parse(["kind": "reflections"])
        let native = try request.mosaicQuery(now: now, timeZone: losAngeles)
        XCTAssertEqual(cli.endDay, native.endDay)
        XCTAssertEqual(NivoJigsawQuery.date(cli.endDay), "2026-11-15")
    }

    func testMosaicAcceptsDisplayTitleButStillRejectsUnknownOrIllTypedFields() throws {
        let query = try NivoJigsawQuery.parseTool(["kind": "stats", "days": 7, "tool_title": "Review saved fragments"])
        XCTAssertEqual(query.command, "stats")
        XCTAssertEqual(query.endDay - query.startDay, 6)
        XCTAssertThrowsError(try NivoJigsawQuery.parseTool(["kind": "list", "owner": "other"]))
        XCTAssertThrowsError(try NivoJigsawQuery.parseTool(["kind": "list", "days": true]))
        XCTAssertThrowsError(try NivoJigsawQuery.parseTool(["kind": "list", "days": NSNull()]))
        XCTAssertThrowsError(try NivoJigsawQuery.parseTool(["tool_title": 42]))
    }

    func testJsonAndMarkdownDeclareNextOffsetIncludingEmptyFinalPage() throws {
        for command in ["list", "export"] {
            for format in ["json", "md"] {
                let arguments = [command, "--start", "1970-01-01", "--end", "1970-01-03", "--limit", "2", "--format", format]
                let first = try NivoJigsawQuery.parse(arguments)
                let last = try NivoJigsawQuery.parse(arguments + ["--offset", "2"])
                let state = NivoMosaicState(ownerKey: "isolated-test")
                let firstOutput = try NivoJigsawOutput.render(query: first, state: state)
                let lastOutput = try NivoJigsawOutput.render(query: last, state: state)
                if format == "json" {
                    XCTAssertEqual(try object(firstOutput)["next_offset"] as? Int, 2)
                    XCTAssertTrue(try object(lastOutput)["next_offset"] is NSNull)
                } else {
                    XCTAssertTrue(firstOutput.contains("next_offset: 2"))
                    XCTAssertTrue(lastOutput.contains("next_offset: null"))
                    XCTAssertTrue(lastOutput.contains("has_more: false"))
                }
            }
        }
    }

    private func object(_ output: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
    }
}
