import XCTest
@testable import Minis

/// 默认种子的跨语言和历史兼容规则只识别完整模板，保留所有自定义内容。
final class NivoSoulDefaultsTests: XCTestCase {
    private let chineseSeed = "---\nname: \"十七\"\nstyle: \"\"\nlang: \"auto\"\n---\n"
    private let englishSeed = "---\nname: \"Shiqi\"\nstyle: \"\"\nlang: \"auto\"\n---\n"
    private let upstreamSeed = "---\nname: \"nanoMuse\"\nstyle: \"\"\nlang: \"auto\"\n---\n"
    private let previousSeed = "---\nname: \"Nivo Bot\"\nstyle: \"\"\nlang: \"auto\"\n---\n"

    /// 生成内容沿用已有模板及其末尾换行，便于无损接入首次启动逻辑。
    func testContentPreservesExactExistingTemplate() {
        XCTAssertEqual(NivoSoulDefaults.content(name: "十七"), chineseSeed)
        XCTAssertEqual(NivoSoulDefaults.content(name: "Shiqi"), englishSeed)
    }

    /// 两种当前角色名均可识别，判断结果不依赖应用当前语言。
    func testRecognizesBothCurrentLanguageSeeds() {
        XCTAssertTrue(NivoSoulDefaults.isDefaultContent(chineseSeed))
        XCTAssertTrue(NivoSoulDefaults.isDefaultContent(englishSeed))
    }

    /// 已核实的两个历史版本模板仍被识别为默认种子。
    func testRecognizesHistoricalSeeds() {
        XCTAssertTrue(NivoSoulDefaults.isDefaultContent(upstreamSeed))
        XCTAssertTrue(NivoSoulDefaults.isDefaultContent(previousSeed))
    }

    /// 另一语言的默认种子不能覆盖已有自定义正文。
    func testCrossLanguageSeedsPreserveCustomizedLocalContent() {
        XCTAssertTrue(NivoSoulDefaults.shouldPreserveLocalContent(
            local: chineseSeed + "请先核实证据再回答。\n", remote: englishSeed
        ))
        XCTAssertTrue(NivoSoulDefaults.shouldPreserveLocalContent(
            local: englishSeed + "Keep my project terminology.\n", remote: chineseSeed
        ))
    }

    /// 历史默认种子不能覆盖已有自定义角色和正文。
    func testHistoricalSeedsPreserveCustomizedLocalContent() {
        let customized = "---\nname: \"阿橙\"\nstyle: \"简洁\"\nlang: \"zh\"\n---\n保留我的资料。\n"
        for remoteSeed in [upstreamSeed, previousSeed] {
            XCTAssertTrue(NivoSoulDefaults.shouldPreserveLocalContent(
                local: customized, remote: remoteSeed
            ))
        }
    }

    /// 仅兼容Windows换行，不因此改变模板的其他文字或结构。
    func testCRLFSeedsAreRecognizedAndProtectCustomizedContent() {
        for seed in [chineseSeed, englishSeed, upstreamSeed, previousSeed] {
            let windowsSeed = seed.replacingOccurrences(of: "\n", with: "\r\n")
            XCTAssertTrue(NivoSoulDefaults.isDefaultContent(windowsSeed))
            XCTAssertTrue(NivoSoulDefaults.shouldPreserveLocalContent(
                local: chineseSeed + "自定义正文\n", remote: windowsSeed
            ))
        }
    }

    /// 默认昵称加自定义正文仍是用户内容，不能仅凭昵称判定。
    func testKnownDefaultNameWithBodyIsCustomized() {
        for seed in [chineseSeed, englishSeed, upstreamSeed, previousSeed] {
            XCTAssertFalse(NivoSoulDefaults.isDefaultContent(seed + "自定义正文\n"))
        }
    }

    /// 额外的frontmatter字段代表用户编辑，不属于默认种子。
    func testAdditionalFrontmatterFieldIsCustomized() {
        let customized = chineseSeed.replacingOccurrences(
            of: "lang: \"auto\"\n", with: "lang: \"auto\"\ncustom: \"保留\"\n"
        )
        XCTAssertFalse(NivoSoulDefaults.isDefaultContent(customized))
        XCTAssertTrue(NivoSoulDefaults.shouldPreserveLocalContent(
            local: customized, remote: chineseSeed
        ))
    }

    /// 自定义风格不能被当作默认种子抹掉。
    func testCustomizedStyleIsNotDefault() {
        let customized = chineseSeed.replacingOccurrences(
            of: "style: \"\"", with: "style: \"简洁\""
        )
        XCTAssertFalse(NivoSoulDefaults.isDefaultContent(customized))
    }

    /// 显式指定回复语言即为自定义内容。
    func testCustomizedLanguageIsNotDefault() {
        let customized = chineseSeed.replacingOccurrences(
            of: "lang: \"auto\"", with: "lang: \"zh\""
        )
        XCTAssertFalse(NivoSoulDefaults.isDefaultContent(customized))
    }

    /// 没有正文的用户昵称也必须保留，未知名字不扩大为默认种子。
    func testCustomNameWithoutBodyIsNotDefault() {
        let customized = chineseSeed.replacingOccurrences(of: "十七", with: "阿橙")
        XCTAssertFalse(NivoSoulDefaults.isDefaultContent(customized))
        XCTAssertTrue(NivoSoulDefaults.shouldPreserveLocalContent(
            local: customized, remote: englishSeed
        ))
    }

    /// 真实远端自定义更新仍交给原有时间戳规则处理。
    func testRealCustomizedRemoteUpdateRemainsAllowed() {
        let remote = englishSeed + "新的用户偏好\n"
        XCTAssertFalse(NivoSoulDefaults.shouldPreserveLocalContent(
            local: chineseSeed, remote: remote
        ))
        XCTAssertFalse(NivoSoulDefaults.shouldPreserveLocalContent(
            local: chineseSeed + "旧的用户偏好\n", remote: remote
        ))
    }

    /// 已知默认种子之间不触发自定义内容保护，换行差异也不阻断。
    func testKnownDefaultSeedsCanReplaceEachOther() {
        let seeds = [chineseSeed, englishSeed, upstreamSeed, previousSeed]
        for local in seeds {
            for remote in seeds {
                XCTAssertFalse(NivoSoulDefaults.shouldPreserveLocalContent(
                    local: local.replacingOccurrences(of: "\n", with: "\r\n"), remote: remote
                ))
            }
        }
    }

    /// 重复生成当前默认内容保持一致，接收端既有全文相等短路仍适用。
    func testRepeatedCurrentDefaultRemainsIdentical() {
        let first = NivoSoulDefaults.content(name: "十七")
        let second = NivoSoulDefaults.content(name: "十七")
        XCTAssertEqual(first, second)
        XCTAssertFalse(NivoSoulDefaults.shouldPreserveLocalContent(local: first, remote: second))
    }

    /// 不去除额外空白或宽松解析字段，避免把手工编辑扩大为默认内容。
    func testExtraWhitespaceOrChangedStructureIsNotDefault() {
        XCTAssertFalse(NivoSoulDefaults.isDefaultContent(" " + chineseSeed))
        XCTAssertFalse(NivoSoulDefaults.isDefaultContent(chineseSeed + "\n"))
        XCTAssertFalse(NivoSoulDefaults.isDefaultContent(
            chineseSeed.replacingOccurrences(of: "style: \"\"", with: "style: ''")
        ))
    }

    /// 两个实际历史版本的完整默认文件可迁移到当前语言的助手名。
    func testLegacyDefaultsMigrateToRequestedAssistantName() {
        for legacy in [upstreamSeed, previousSeed] {
            XCTAssertEqual(NivoSoulDefaults.migratedLegacyContent(
                legacy, assistantName: "十七"
            ), chineseSeed)
            XCTAssertEqual(NivoSoulDefaults.migratedLegacyContent(
                legacy, assistantName: "Shiqi"
            ), englishSeed)
        }
    }

    /// CRLF历史模板允许迁移，写回当前模板的标准换行。
    func testLegacyCRLFDefaultMigrates() {
        XCTAssertEqual(NivoSoulDefaults.migratedLegacyContent(
            upstreamSeed.replacingOccurrences(of: "\n", with: "\r\n"),
            assistantName: "十七"
        ), chineseSeed)
    }

    /// 当前版本的助手名不随每次启动语言变更而被再次改写。
    func testCurrentDefaultNamesAreNotLegacyMigrationCandidates() {
        XCTAssertNil(NivoSoulDefaults.migratedLegacyContent(chineseSeed, assistantName: "Shiqi"))
        XCTAssertNil(NivoSoulDefaults.migratedLegacyContent(englishSeed, assistantName: "十七"))
    }

    /// 任何自定义正文、字段、语言、风格、未知昵称或空白都禁止自动改写。
    func testLegacyMigrationPreservesEveryCustomizedVariant() {
        let variants = [
            upstreamSeed + "我的偏好\n",
            upstreamSeed + "\n",
            " " + upstreamSeed,
            upstreamSeed.replacingOccurrences(of: "style: \"\"", with: "style: \"简洁\""),
            upstreamSeed.replacingOccurrences(of: "lang: \"auto\"", with: "lang: \"zh\""),
            upstreamSeed.replacingOccurrences(of: "lang: \"auto\"\n", with: "lang: \"auto\"\nicon: \"\"\n"),
            upstreamSeed.replacingOccurrences(of: "nanoMuse", with: "阿橙"),
            upstreamSeed.replacingOccurrences(of: "style: \"\"", with: "style: ''"),
        ]
        for customized in variants {
            XCTAssertNil(NivoSoulDefaults.migratedLegacyContent(customized, assistantName: "十七"))
        }
    }

    /// 空文件和非完整模板不得因自动迁移而变成新的身份文件。
    func testLegacyMigrationRejectsEmptyAndIncompleteContent() {
        XCTAssertNil(NivoSoulDefaults.migratedLegacyContent("", assistantName: "十七"))
        XCTAssertNil(NivoSoulDefaults.migratedLegacyContent("name: \"nanoMuse\"", assistantName: "十七"))
    }

    /// 实际文件迁移只发生一次，之后不受当前显示语言影响。
    func testLegacyFileMigrationIsIdempotent() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("SOUL.md")
        try previousSeed.write(to: file, atomically: true, encoding: .utf8)
        XCTAssertTrue(try NivoSoulDefaults.migrateLegacyFile(at: file, assistantName: "十七"))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), chineseSeed)
        XCTAssertFalse(try NivoSoulDefaults.migrateLegacyFile(at: file, assistantName: "Shiqi"))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), chineseSeed)
    }

    /// 文件包含自定义正文或无法解码时，原始字节保持不变。
    func testLegacyFileMigrationPreservesCustomizedAndUnreadableBytes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("SOUL.md")
        let customized = Data((previousSeed + "保留正文\n").utf8)
        try customized.write(to: file)
        XCTAssertFalse(try NivoSoulDefaults.migrateLegacyFile(at: file, assistantName: "十七"))
        XCTAssertEqual(try Data(contentsOf: file), customized)
        let unreadable = Data([0xFF, 0xFE, 0xFF])
        try unreadable.write(to: file)
        XCTAssertThrowsError(try NivoSoulDefaults.migrateLegacyFile(at: file, assistantName: "十七"))
        XCTAssertEqual(try Data(contentsOf: file), unreadable)
    }

    /// 迁移不负责创建缺失文件，首次播种仍由宿主的原有流程处理。
    func testLegacyFileMigrationDoesNotCreateMissingFile() {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("SOUL.md")
        XCTAssertThrowsError(try NivoSoulDefaults.migrateLegacyFile(at: file, assistantName: "十七"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }
}
