import XCTest
@testable import Minis

/// 环形分组统计与实际区间相符，不能包含休息或把跨日期时间重复计数。
final class NivoFocusStatisticsTests: XCTestCase {
    func testDistributionSplitsBoundaryAndKeepsOriginalGroupSnapshot() throws {
        let sessions = try [session("study", group: "Study"), session("work", group: "Work"), session("none", group: "")]
        let spans = [span("study", start: 900, duration: 300), span("work", start: 1_100, duration: 500),
                     span("none", start: 1_900, duration: 200)]
        let result = NivoFocusStatistics.distribution(sessions: sessions, spans: spans, startMs: 1_000, endMs: 2_000)
        XCTAssertEqual(result.groups, [.init(group: "Work", durationMs: 500), .init(group: "Study", durationMs: 200),
                                       .init(group: "", durationMs: 100)])
        XCTAssertEqual(result.totalMs, 800)
        XCTAssertEqual(result.totalMs, NivoFocusRules.duration(sessions: sessions, spans: spans, startMs: 1_000, endMs: 2_000))
        let next = NivoFocusStatistics.distribution(sessions: sessions, spans: spans, startMs: 2_000, endMs: 3_000)
        XCTAssertEqual(next.groups, [.init(group: "", durationMs: 100)])
    }

    func testDistributionExcludesBreakUnfinishedDeletedAndUnknownSessions() throws {
        let finished = try session("finished", group: "Work")
        var rest = try session("rest", group: "Break")
        rest.mode = .rest
        var running = try session("running", group: "Running")
        running.status = .running
        var paused = try session("paused", group: "Paused")
        paused.status = .paused
        var deleted = try session("deleted", group: "Deleted")
        deleted.deletedAt = 2_000
        let sessions = [finished, rest, running, paused, deleted]
        let spans = sessions.map { span($0.id, start: 1_000, duration: 100) } + [span("missing", start: 1_000, duration: 900)]
        let result = NivoFocusStatistics.distribution(sessions: sessions, spans: spans, startMs: 1_000, endMs: 2_000)
        XCTAssertEqual(result.groups, [.init(group: "Work", durationMs: 100)])
        XCTAssertEqual(result.totalMs, 100)
    }

    func testRepeatedSpansAggregateAndEqualDurationsKeepStableOrdering() throws {
        let sessions = try [session("a", group: "Alpha"), session("b", group: "Beta")]
        let spans = [span("b", start: 1_000, duration: 100), span("a", start: 1_200, duration: 40),
                     span("a", start: 1_500, duration: 60), span("b", start: 2_000, duration: 500)]
        let result = NivoFocusStatistics.distribution(sessions: sessions, spans: spans, startMs: 1_000, endMs: 2_000)
        XCTAssertEqual(result.groups, [.init(group: "Alpha", durationMs: 100), .init(group: "Beta", durationMs: 100)])
        XCTAssertEqual(NivoFocusStatistics.distribution(sessions: sessions, spans: spans, startMs: 2_000, endMs: 1_000).totalMs, 0)
    }

    private func session(_ identifier: String, group: String) throws -> NivoFocusSession {
        var session = try NivoFocusRules.start(owner: "local", id: identifier, title: "Read", task: nil,
            mode: .pomodoro, minutes: 3, clock: NivoFocusClockSample(wallMs: 1_000, elapsedMs: 0, bootID: "boot"))
        session.groupName = group
        session.status = .finished
        return session
    }

    private func span(_ sessionID: String, start: Int64, duration: Int64) -> NivoFocusSpan {
        NivoFocusSpan(id: UUID().uuidString, sessionId: sessionID, startedAt: start, durationMs: duration)
    }
}
