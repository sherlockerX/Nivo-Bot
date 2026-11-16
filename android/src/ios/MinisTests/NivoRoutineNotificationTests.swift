import XCTest
@testable import Minis

/// 通知只以已提交记录去重，失败和静音不会被混为没有执行。
final class NivoRoutineNotificationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)
    private var row: NanoMuseRoutine {
        NanoMuseRoutine(label: "Read", prompt: "Review", hour: 9, minute: 0, execution: NivoRoutineExecution())
    }

    func testQuietHoursCrossMidnightAndExcludeEnd() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let morning = ISO8601DateFormatter().date(from: "2026-11-14T06:59:00Z")!
        XCTAssertTrue(NivoRoutineNotificationRules.isQuiet("22:00-07:00", at: morning, calendar: calendar))
        XCTAssertFalse(NivoRoutineNotificationRules.isQuiet("22:00-07:00", at: morning.addingTimeInterval(60), calendar: calendar))
        XCTAssertFalse(NivoRoutineNotificationRules.isQuiet("off", at: morning, calendar: calendar))
        XCTAssertThrowsError(try NivoRoutineNotificationRules.validateQuietHours("22:00-07:00-09:00"))
        XCTAssertThrowsError(try NivoRoutineNotificationRules.validateQuietHours("25:00-07:00"))
    }

    func testUnsubmittedNotificationDoesNotSuppressRetry() {
        var task = row
        var previous = NanoMuseRoutine.Run(at: now.addingTimeInterval(-100), ok: true, id: "previous", result: "Read notes")
        previous.notification = NivoRoutineNotificationDecision(shouldNotify: true, reason: "changed", deliveryError: "denied")
        task.runs = [previous]
        let run = NanoMuseRoutine.Run(at: now, ok: true, id: "current", result: "Read notes")
        XCTAssertTrue(decide(task, run).shouldNotify)
        task.runs[0].notification?.submittedAt = now.addingTimeInterval(-100)
        XCTAssertEqual(decide(task, run).reason, "unchanged")
        task.runs[0].notification?.submittedAt = now.addingTimeInterval(-6 * 3_600)
        XCTAssertTrue(decide(task, run).shouldNotify)
    }

    func testFailureOnlyAndExplicitNoOutput() {
        var task = row
        task.execution?.notification = NivoRoutineNotificationOptions(policy: .onFailure)
        XCTAssertEqual(decide(task, NanoMuseRoutine.Run(at: now, ok: true, result: "Answer")).reason, "policy_on_failure")
        XCTAssertTrue(decide(task, NanoMuseRoutine.Run(at: now, ok: false, note: "timeout")).shouldNotify)
        XCTAssertEqual(decide(row, NanoMuseRoutine.Run(at: now, ok: true, result: "\nNO_OUTPUT ")).reason, "empty")
    }

    func testDryRunAndHourlyLimit() {
        let run = NanoMuseRoutine.Run(at: now, ok: true, result: "Answer")
        XCTAssertEqual(NivoRoutineNotificationRules.decide(row: row, run: run, allRows: [],
            settings: NivoRoutineNotificationSettings(), now: now, dryNotify: true).reason, "dry_notify")
        var other = row
        other.runs = (0..<10).map { index in
            NanoMuseRoutine.Run(at: now.addingTimeInterval(-10), ok: true, id: String(index),
                notification: NivoRoutineNotificationDecision(shouldNotify: true, reason: "changed", submittedAt: now.addingTimeInterval(-10)))
        }
        XCTAssertEqual(NivoRoutineNotificationRules.decide(row: row, run: run, allRows: [other],
            settings: NivoRoutineNotificationSettings(), now: now, dryNotify: false).reason, "rate_limited")
    }

    private func decide(_ row: NanoMuseRoutine, _ run: NanoMuseRoutine.Run) -> NivoRoutineNotificationDecision {
        NivoRoutineNotificationRules.decide(row: row, run: run, allRows: [row],
            settings: NivoRoutineNotificationSettings(quietHours: "off"), now: now, dryNotify: false)
    }
}
