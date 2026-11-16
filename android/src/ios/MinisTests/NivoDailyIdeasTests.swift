import XCTest
@testable import Minis

/// 直接读取正式打包目录，验证每日轮换不会长期退回相同占位内容。
final class NivoDailyIdeasTests: XCTestCase {
    func testBundledCatalogueContainsAllSevenCategoriesAndSevenDaysOfIdeas() throws {
        for language in ["en", "zh"] {
            let sections = try NivoDailyIdeas.parse(resource("daily-ideas." + language))
            XCTAssertEqual(sections.map(\.category), NivoDailyIdeaCategory.allCases)
            XCTAssertEqual(sections.map { $0.ideas.count }, Array(repeating: 14, count: 7))
            XCTAssertEqual(Set(sections.flatMap(\.ideas).map(\.id)).count, 98)
        }
    }

    func testSelectionMatchesAndroidEpochDayWithoutCategoryOffset() {
        let calendar = calendar("GMT")
        let day = Date(timeIntervalSince1970: 0)
        let pool = (0..<14).map { idea(String(format: "work-%02d", $0), category: .work) }
        XCTAssertEqual(NivoDailyIdeas.select(pool, day: day, category: .work, calendar: calendar).map(\.id), ["work-00", "work-01"])
    }

    func testSevenDayRotationIsStableAndCoversEveryBundledIdea() throws {
        let sections = try NivoDailyIdeas.parse(resource("daily-ideas.en"))
        let calendar = calendar("America/Chicago")
        let first = Date(timeIntervalSince1970: 1_793_556_000)
        var selected: [String] = []
        for offset in 0..<7 {
            let day = try XCTUnwrap(calendar.date(byAdding: .day, value: offset, to: first))
            let morning = NivoDailyIdeas.edition(sections: sections, for: day, calendar: calendar)
            selected += morning.sections.flatMap(\.ideas).map(\.id)
            XCTAssertEqual(morning.sections.map { $0.ideas.count }, Array(repeating: 2, count: 7))
        }
        XCTAssertEqual(Set(selected).count, 98)
        let repeatDate = try XCTUnwrap(calendar.date(byAdding: .day, value: 7, to: first))
        XCTAssertEqual(NivoDailyIdeas.edition(sections: sections, for: first, calendar: calendar).sections,
                       NivoDailyIdeas.edition(sections: sections, for: repeatDate, calendar: calendar).sections)
    }

    func testMalformedItemAndDuplicateIDDoNotHideOtherCategories() throws {
        let data = Data(#"{"sections":[{"id":"ideas","ideas":[{"id":"valid","title":"A","body":"B","prompt":"P"},{"id":"broken","title":"Missing fields"}]},{"id":"work","ideas":[{"id":"valid","title":"Duplicate","body":"B","prompt":"P"},{"id":"second","title":"C","body":"D","prompt":"Q"}]},{"id":"unknown","ideas":[]}]}"#.utf8)
        let sections = try NivoDailyIdeas.parse(data)
        XCTAssertEqual(sections.map(\.category), [.ideas, .work])
        XCTAssertEqual(sections.flatMap(\.ideas).map(\.id), ["valid", "second"])
        XCTAssertThrowsError(try NivoDailyIdeas.parse(Data("[]".utf8)))
    }

    func testSelectionUsesRequestedLocalDateIncludingBeforeEpoch() {
        let pool = (0..<14).map { idea(String(format: "idea-%02d", $0)) }
        let sections = [NivoDailyIdeaSection(category: .ideas, ideas: pool)]
        let instant = Date(timeIntervalSince1970: 0)
        let west = NivoDailyIdeas.edition(sections: sections, for: instant, calendar: calendar("America/New_York"))
        let east = NivoDailyIdeas.edition(sections: sections, for: instant, calendar: calendar("Asia/Tokyo"))
        XCTAssertEqual(west.sections[0].ideas.map(\.id), ["idea-12", "idea-13"])
        XCTAssertEqual(east.sections[0].ideas.map(\.id), ["idea-00", "idea-01"])
    }

    func testSameLocalDayIsStableAcrossUTCDateChange() throws {
        let sections = try NivoDailyIdeas.parse(resource("daily-ideas.en"))
        let zone = calendar("Asia/Tokyo")
        let morning = try instant("2026-11-14T16:00:00Z")
        let evening = try instant("2026-11-15T13:00:00Z")
        XCTAssertEqual(NivoDailyIdeas.edition(sections: sections, for: morning, calendar: zone),
                       NivoDailyIdeas.edition(sections: sections, for: evening, calendar: zone))
    }

    func testRefreshChecksClockWithinAMinuteAndRespectsDSTMidnight() throws {
        let zone = calendar("America/Chicago")
        XCTAssertEqual(NivoDailyIdeas.refreshDelay(now: try instant("2024-03-10T20:00:00Z"), calendar: zone), 60)
        XCTAssertEqual(NivoDailyIdeas.refreshDelay(now: try instant("2024-03-11T04:59:59Z"), calendar: zone), 1)
        XCTAssertEqual(NivoDailyIdeas.refreshDelay(now: try instant("2024-11-04T05:59:59Z"), calendar: zone), 1)
    }

    func testHotTopicTemplateIncludesDisplayedLocalDateAndSourceChecks() throws {
        let date = try instant("2026-11-15T01:00:00Z")
        let english = try NivoDailyIdeas.hotTopicPrompt(for: date, language: "fr", calendar: calendar("America/Chicago"))
        XCTAssertTrue(english.contains("2026-11-14"))
        XCTAssertTrue(english.contains("at least two independently checkable sources"))
        XCTAssertTrue(english.contains("Do not publish content or create scheduled tasks."))
        let chinese = try NivoDailyIdeas.hotTopicPrompt(for: date, language: "zh-Hant", calendar: calendar("Asia/Shanghai"))
        XCTAssertTrue(chinese.contains("2026-11-15"))
        XCTAssertTrue(chinese.contains("不要发布内容或自动创建定时任务"))
        XCTAssertFalse(chinese.contains("$date"))
    }

    func testVerifiedHotTopicRejectsMissingHostsCredentialsAndOldEvidence() throws {
        let now = try instant("2026-11-15T12:00:00Z")
        var item = idea("story", category: .media)
        item.isHotTopic = true
        item.source = NivoDailyIdeaSource(publisher: "Publisher", url: "https://example.org/story",
            publishedAt: now.addingTimeInterval(-3600), verifiedAt: now)
        XCTAssertTrue(item.hasVerifiedHotTopic(now: now))
        for url in ["https:/story", "https://name@example.org/story", "http://example.org/story"] {
            item.source?.url = url
            XCTAssertFalse(item.hasVerifiedHotTopic(now: now))
        }
        item.source?.url = "https://example.org/story"
        item.source?.publishedAt = now.addingTimeInterval(-49 * 3600)
        XCTAssertFalse(item.hasVerifiedHotTopic(now: now))
        item.source?.publishedAt = now.addingTimeInterval(60)
        XCTAssertFalse(item.hasVerifiedHotTopic(now: now))
    }

    func testSourceParsingPreservesValidDatesAndDropsMalformedSourceOnly() throws {
        let data = Data(#"{"sections":[{"id":"media","ideas":[{"id":"story","title":"A","body":"B","prompt":"P","hot":true,"source":{"publisher":"Publisher","url":"https://example.org/story","publishedAt":"2026-11-15T10:00:00.123Z","verifiedAt":"2026-11-15T11:00:00Z"}},{"id":"bad-source","title":"C","body":"D","prompt":"Q","hot":true,"source":{"publishedAt":"invalid"}}]}]}"#.utf8)
        let items = try XCTUnwrap(NivoDailyIdeas.parse(data).first).ideas
        XCTAssertEqual(items.count, 2)
        XCTAssertTrue(items[0].hasVerifiedHotTopic(now: try instant("2026-11-15T12:00:00Z")))
        XCTAssertNil(items[1].source)
        XCTAssertFalse(items[1].hasVerifiedHotTopic())
    }

    private func idea(_ identifier: String, category: NivoDailyIdeaCategory = .ideas) -> NivoDailyIdea {
        NivoDailyIdea(id: identifier, category: category, emoji: "💡", title: "Title", body: "Body", prompt: "Prompt")
    }

    private func calendar(_ name: String) -> Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = TimeZone(identifier: name)!
        return result
    }

    private func resource(_ name: String) throws -> Data {
        try NivoDailyIdeas.resourceData(name)
    }

    private func instant(_ text: String) throws -> Date {
        try XCTUnwrap(ISO8601DateFormatter().date(from: text))
    }
}
