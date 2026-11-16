import XCTest
@testable import Minis

/// 使用实际日期索引验证重复日期、未安排任务及跨月边界。
final class NivoTodoCalendarTests: XCTestCase {
    func testIndexDeduplicatesSameDayPreservesOrderAndKeepsUndatedTasks() {
        let first = NivoTodoTask(ownerKey: "local", id: "first", title: "First", scheduledDay: 10, dueDay: 10)
        let second = NivoTodoTask(ownerKey: "local", id: "second", title: "Second", scheduledDay: 10, dueDay: 11)
        let undated = NivoTodoTask(ownerKey: "local", id: "undated", title: "No dates")
        var deleted = first
        deleted.id = "deleted"
        deleted.deletedAt = 1
        let index = NivoTodoCalendarIndex(tasks: [first, undated, second, deleted])
        XCTAssertEqual(index.byDay[10]?.map(\.id), ["first", "second"])
        XCTAssertEqual(index.byDay[11]?.map(\.id), ["second"])
        XCTAssertEqual(index.undated.map(\.id), ["undated"])
    }

    func testMonthGridRespectsWeekStartAndLeapYear() throws {
        var calendar = try calendar()
        calendar.firstWeekday = 2
        let february = NivoTodoCalendarMonth(selected: try date(2024, 2, 10, calendar: calendar), calendar: calendar)
        XCTAssertEqual(february.days.count, 29)
        XCTAssertEqual(february.leadingEmptyCells, 3)
        calendar.firstWeekday = 1
        XCTAssertEqual(NivoTodoCalendarMonth(selected: try date(2024, 2, 10, calendar: calendar), calendar: calendar).leadingEmptyCells, 4)
    }

    func testMovingMonthClampsDayAndRejectsOutsideSupportedYear() throws {
        let calendar = try calendar()
        let moved = try XCTUnwrap(NivoTodoCalendarMonth.moving(try date(2026, 1, 31, calendar: calendar), months: 1, calendar: calendar))
        XCTAssertEqual(calendar.component(.month, from: moved), 2)
        XCTAssertEqual(calendar.component(.day, from: moved), 28)
        XCTAssertEqual(calendar.component(.hour, from: moved), 12)
        let last = try date(9999, 12, 15, calendar: calendar)
        XCTAssertNil(NivoTodoCalendarMonth.moving(last, months: 1, calendar: calendar))
    }

    func testDaylightSavingMonthHasContinuousDayIdentifiers() throws {
        let calendar = try calendar()
        let march = NivoTodoCalendarMonth(selected: try date(2026, 3, 8, calendar: calendar), calendar: calendar)
        XCTAssertEqual(march.days.count, 31)
        for (previous, next) in zip(march.days, march.days.dropFirst()) { XCTAssertEqual(next - previous, 1) }
        for day in march.days {
            XCTAssertEqual(NivoLifeDay.value(NivoLifeDay.date(day, timeZone: calendar.timeZone), timeZone: calendar.timeZone), day)
        }
    }

    private func calendar() throws -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, calendar: Calendar) throws -> Date {
        try XCTUnwrap(calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12)))
    }
}
