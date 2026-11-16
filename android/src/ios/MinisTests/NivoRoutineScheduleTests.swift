import XCTest
@testable import Minis

/// 固定公历和时区验证真实调度规则，不修改用户任务或调用模型。
final class NivoRoutineScheduleTests: XCTestCase {
    func testNotificationSettingsAndExplicitFalseAreAccepted() throws {
        let settings = try NivoScheduledCommand.parse(["settings", "--quiet-hours", "22:00-07:00"])
        XCTAssertEqual(settings.value("quiet-hours"), "22:00-07:00")
        let update = try NivoScheduledCommand.parse(["update", "--notify", "on_failure", "--silent=false"])
        XCTAssertEqual(update.value("silent"), "false")
        XCTAssertEqual(update.value("notify"), "on_failure")
    }

    private func calendar(_ zone: String = "UTC") -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }

    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

    private func routine() -> NanoMuseRoutine {
        NanoMuseRoutine(label: "Read", prompt: "Review notes", hour: 8, minute: 0,
            createdAt: date("2026-11-14T07:00:00Z"), schedule: NivoRoutineSchedule(), execution: NivoRoutineExecution())
    }

    func testMultipleTimesAdvanceWithoutReplayingEarlierSlots() {
        var row = routine()
        row.schedule?.times = [NivoRoutineTime(hour: 8, minute: 0), NivoRoutineTime(hour: 18, minute: 30)]
        row.lastFiredAt = date("2026-11-14T12:00:00Z")
        XCTAssertEqual(row.nextDue(after: date("2026-11-14T12:01:00Z"), calendar: calendar()), date("2026-11-14T18:30:00Z"))
    }

    func testOverdueOnceKeepsItsOriginalDay() {
        var row = routine()
        row.repeatMode = .once
        XCTAssertEqual(row.nextDue(after: date("2026-11-16T07:00:00Z"), calendar: calendar()), date("2026-11-14T08:00:00Z"))
        row.lastFiredAt = date("2026-11-16T07:00:01Z")
        XCTAssertNil(row.nextDue(after: date("2026-11-16T08:00:00Z"), calendar: calendar()))
    }

    func testCustomMondayRespectsInclusiveEndDate() {
        var row = routine()
        row.repeatMode = .custom
        row.schedule?.customDays = [2]
        row.schedule?.endDay = NivoLifeDay.value(date("2026-11-16T12:00:00Z"), timeZone: calendar().timeZone)
        XCTAssertEqual(row.nextDue(after: date("2026-11-14T09:00:00Z"), calendar: calendar()), date("2026-11-16T08:00:00Z"))
        XCTAssertNil(row.nextDue(after: date("2026-11-17T09:00:00Z"), calendar: calendar()))
    }

    func testIntervalWaitsForStartDate() {
        var row = routine()
        row.schedule?.intervalMinutes = 30
        row.schedule?.startDay = NivoLifeDay.value(date("2026-11-16T12:00:00Z"), timeZone: calendar().timeZone)
        XCTAssertEqual(row.nextDue(after: date("2026-11-14T09:00:00Z"), calendar: calendar()), date("2026-11-16T00:00:00Z"))
    }

    func testDaylightSavingGapMovesToNextValidLocalTime() {
        var row = routine()
        row.createdAt = date("2026-03-08T05:00:00Z")
        row.hour = 2
        row.minute = 30
        let local = calendar("America/New_York")
        XCTAssertEqual(row.nextDue(after: row.createdAt, calendar: local), date("2026-03-08T07:00:00Z"))
    }

    func testRepeatedDaylightSavingHourRunsOnlyOnce() {
        var row = routine()
        row.createdAt = date("2026-11-01T04:00:00Z")
        row.hour = 1
        row.minute = 30
        let local = calendar("America/New_York")
        row.lastFiredAt = date("2026-11-01T05:30:00Z")
        XCTAssertEqual(row.nextDue(after: date("2026-11-01T06:10:00Z"), calendar: local), date("2026-11-02T06:30:00Z"))
    }

    func testNotificationsIncludeLaterTimesWhenFirstSlotWasMissed() {
        var row = routine()
        row.schedule?.times = [NivoRoutineTime(hour: 18, minute: 0), NivoRoutineTime(hour: 20, minute: 0)]
        let dates = NivoRoutineScheduleRules.notificationDates(row, after: date("2026-11-14T09:00:00Z"), limit: 3, calendar: calendar())
        XCTAssertEqual(dates, [date("2026-11-14T18:00:00Z"), date("2026-11-14T20:00:00Z"), date("2026-11-15T08:00:00Z")])
        XCTAssertNil(row.lastFiredAt)
    }

    func testCLIAcceptsExplicitScriptWithoutModelPrompt() throws {
        let command = try NivoScheduledCommand.parse(["create", "--time", "08:00", "--script", "daily.py",
            "--script-arg", "a; $(literal)", "--script-arg", "", "--require-output"])
        let row = try command.applying(to: nil)
        XCTAssertEqual(row.label, "daily.py")
        XCTAssertTrue(row.prompt.isEmpty)
    }

    func testCLIReportUsesNativeContextInsteadOfCallerDeclaredIdentity() throws {
        let command = try NivoScheduledCommand.parse(["report", "--status", "failure", "--reason", "No records"])
        XCTAssertEqual(command.value("status"), "failure")
        XCTAssertThrowsError(try NivoScheduledCommand.parse(["report", "--run-id", UUID().uuidString, "--status", "success"]))
    }

    func testCLIRejectsMalformedTimeAndDuplicatePrompt() throws {
        let command = try NivoScheduledCommand.parse(["create", "--time", "25:00", "--prompt", "Read"])
        XCTAssertThrowsError(try command.applying(to: nil))
        XCTAssertThrowsError(try NivoScheduledCommand.parse(["create", "--prompt", "one", "--prompt", "two"]))
    }

    func testCLILeavesPromptLiteralAndNormalizesWeekdays() throws {
        let prompt = "Review $(notes); this is data"
        let command = try NivoScheduledCommand.parse(["create", "--time", "08:00", "--time", "20:00",
            "--prompt", prompt, "--repeat", "custom", "--days", "mon,wed,mon"])
        let row = try command.applying(to: nil)
        XCTAssertEqual(row.prompt, prompt)
        XCTAssertEqual(row.schedule?.customDays, [2, 4])
        XCTAssertEqual(NivoRoutineScheduleRules.normalizedTimes(row).map(\.text), ["08:00", "20:00"])
    }

    func testArchiveFailureLeavesPreviousFileUntouched() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("routines.json")
        let row = routine()
        try NivoRoutineArchive.write([row], to: file)
        let saved = try Data(contentsOf: file)
        XCTAssertThrowsError(try NivoRoutineArchive.write([row, row], to: file))
        XCTAssertEqual(try Data(contentsOf: file), saved)
        XCTAssertEqual(try NivoRoutineArchive.read(file), [row])
    }
}
