import Foundation
import XCTest
@testable import Minis

/// 预置长期记忆仅在整份文件仍为历史原文时升级，不能局部替换用户记忆。
final class NivoPresetDefaultsTests: XCTestCase {
    private let oldGlobal = """
    # 长期记忆

    ## 关于你自己
    - 你是 Nicholasx，运行在我的 Android 手机上，模型来自我自己配置的服务商。
    - 你看得到 SOUL.md（你的性格）、USER.md（关于我）和这份长期记忆；每天的零碎写进当天的记忆日志。

    ## 关于"拼图"
    - "拼图"页是我的生活记录：每天的照片、一句话和习惯完成情况，只保存在这台手机上。
    - 你现在读不到拼图里的记录。需要复盘时，请我把当天或这周的内容告诉你，或者直接问我。

    ## 约定
    - 我说"记住……"时，把它写进长期记忆或 USER.md，并告诉我写在了哪里。
    - 关于我的长期事实（称呼、作息、目标、重要的人）更新到 USER.md，不要重复堆在这里。
    - 过时或被我纠正的内容，直接改掉，不要留下互相矛盾的两条。

    """
    private let replacement = "# 长期记忆\n\n你的名字以SOUL.md为准。\n"

    /// 新旧设备词形使用同一个转换入口，不改变工具命令或用户文件名。
    func testBundledDeviceWordingAdaptsOldAndCurrentForms() {
        let source = "Android客户端；Android 手机；Android手机；SOUL.md；minis-jigsaw-cli"
        XCTAssertEqual(NivoPresetDefaults.contentForIPhone(source),
                       "iOS客户端；iPhone；iPhone；SOUL.md；minis-jigsaw-cli")
    }

    /// 已适配的iOS资源可以重复转换，不会重新生成Android设备说明。
    func testAdaptedDeviceWordingIsIdempotent() {
        let source = "你运行在Nivo的Android客户端中。"
        let expected = "你运行在Nivo的iOS客户端中。"
        let adapted = NivoPresetDefaults.contentForIPhone(source)
        XCTAssertEqual(adapted, expected)
        XCTAssertEqual(NivoPresetDefaults.contentForIPhone(adapted), expected)
    }

    /// 用实际打包的完整模板核对两个平台的旧版默认记忆，任何个人追加均不得迁移。
    func testUnmodifiedCompanionMemoryMigratesOnce() throws {
        let sourceURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("NanoMuse/Resources/preset.json")
        let url = Bundle.main.url(forResource: "preset", withExtension: "json") ?? sourceURL
        let files = try JSONDecoder().decode([String: [String: String]].self, from: Data(contentsOf: url))
        let android = try XCTUnwrap(files["files"]?["memory/GLOBAL.md"])
        let target = NivoPresetDefaults.contentForIPhone(android)
        XCTAssertTrue(target.contains("在Nivo的iOS客户端"))
        for template in [android, target] {
            let old = template.replacingOccurrences(of: "在Nivo的", with: "在念步（Nelan）的")
            XCTAssertEqual(NivoPresetDefaults.migratedGlobalContent(old, replacement: target), target)
            XCTAssertNil(NivoPresetDefaults.migratedGlobalContent(old + "我叫Nelan。", replacement: target))
        }
        XCTAssertNil(NivoPresetDefaults.migratedGlobalContent(target, replacement: target))
    }

    /// iOS播种时已替换设备名的完整旧模板可以升级。
    func testExactIPhoneGlobalDefaultMigrates() {
        let existing = oldGlobal.replacingOccurrences(of: "Android 手机", with: "iPhone")
        XCTAssertEqual(NivoPresetDefaults.migratedGlobalContent(
            existing, replacement: replacement
        ), replacement)
    }

    /// 旧Android原文与CRLF副本也只能在整文一致时升级。
    func testAndroidAndCRLFGlobalDefaultsMigrate() {
        XCTAssertEqual(NivoPresetDefaults.migratedGlobalContent(
            oldGlobal, replacement: replacement
        ), replacement)
        XCTAssertEqual(NivoPresetDefaults.migratedGlobalContent(
            oldGlobal.replacingOccurrences(of: "\n", with: "\r\n"), replacement: replacement
        ), replacement)
    }

    /// 曾追加记忆、改过事实或调整空白的文件必须完整保留。
    func testCustomizedGlobalMemoryIsNeverReplaced() {
        let variants = [
            oldGlobal + "\n我在学习物理。\n",
            oldGlobal.replacingOccurrences(of: "Nicholasx", with: "阿橙"),
            oldGlobal.replacingOccurrences(of: "模型来自我自己配置的服务商", with: "先核实数据来源"),
            oldGlobal + "\n",
            " " + oldGlobal,
        ]
        for text in variants {
            XCTAssertNil(NivoPresetDefaults.migratedGlobalContent(text, replacement: replacement))
        }
    }

    /// 新资源和已经升级的文件不再触发迁移，避免重复写入。
    func testCurrentGlobalAndUnchangedResourceAreNotRewritten() {
        XCTAssertNil(NivoPresetDefaults.migratedGlobalContent(replacement, replacement: replacement))
        XCTAssertNil(NivoPresetDefaults.migratedGlobalContent(oldGlobal, replacement: oldGlobal))
    }

    /// 空内容、缺失资源和只有旧身份句的文件都不能触发迁移。
    func testMissingOrPartialContentCannotTriggerMigration() {
        XCTAssertNil(NivoPresetDefaults.migratedGlobalContent("", replacement: replacement))
        XCTAssertNil(NivoPresetDefaults.migratedGlobalContent(oldGlobal, replacement: ""))
        XCTAssertNil(NivoPresetDefaults.migratedGlobalContent(
            "- 你是 Nicholasx，运行在我的 iPhone上。\n", replacement: replacement
        ))
    }

    /// 已经播种到磁盘的完整旧文件可升级一次，后续调用保持内容不变。
    func testExistingGlobalFileMigratesIdempotently() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("GLOBAL.md")
        try oldGlobal.replacingOccurrences(of: "Android 手机", with: "iPhone")
            .write(to: file, atomically: true, encoding: .utf8)
        XCTAssertTrue(try NivoPresetDefaults.migrateGlobalFile(at: file, replacement: replacement))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), replacement)
        XCTAssertFalse(try NivoPresetDefaults.migrateGlobalFile(at: file, replacement: replacement))
    }

    /// 实际磁盘中的自定义或无法解码的文件不会因升级而丢失字节。
    func testGlobalFileMigrationPreservesCustomizedAndUnreadableBytes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("GLOBAL.md")
        let customized = Data((oldGlobal + "记住我的偏好。\n").utf8)
        try customized.write(to: file)
        XCTAssertFalse(try NivoPresetDefaults.migrateGlobalFile(at: file, replacement: replacement))
        XCTAssertEqual(try Data(contentsOf: file), customized)
        let undecodable = Data([0xFF, 0xFE, 0xFF])
        try undecodable.write(to: file)
        XCTAssertThrowsError(try NivoPresetDefaults.migrateGlobalFile(at: file, replacement: replacement))
        XCTAssertEqual(try Data(contentsOf: file), undecodable)
    }

    /// 缺失文件由原播种规则处理，迁移函数不创建文件或上级目录。
    func testGlobalMigrationDoesNotCreateMissingFile() {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("GLOBAL.md")
        XCTAssertThrowsError(try NivoPresetDefaults.migrateGlobalFile(at: file, replacement: replacement))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }
}
