import Foundation
import XCTest
@testable import Minis

/// 覆盖升级时的旧资料优先、同名保护，以及失败后再次启动的恢复行为。
final class NivoLegacyStorageMigrationTests: XCTestCase {
    private var root: URL!
    private var layout: NivoStorageLayout!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        layout = NivoStorageLayout(sharedContainer: nil, libraryDirectory: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    func testOldSoulArrivesBeforeDefaultSeeding() throws {
        try write("用户自定义身份", to: root.appendingPathComponent("MinisChat/memory/SOUL.md"))
        try NivoLegacyStorageMigration.migrate(layout: layout)
        let target = layout.applicationFiles.appendingPathComponent("memory/SOUL.md")
        if !FileManager.default.fileExists(atPath: target.path) { try write("默认身份", to: target) }
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "用户自定义身份")
    }

    func testNestedSkillMergesWithoutReplacingEitherConflict() throws {
        let source = root.appendingPathComponent("MinisChat/skills/writing")
        let target = layout.applicationFiles.appendingPathComponent("skills/writing")
        try write("旧课程", to: source.appendingPathComponent("SKILL.md"))
        try write("个人笔记", to: source.appendingPathComponent("notes.md"))
        try write("现有课程", to: target.appendingPathComponent("SKILL.md"))
        try NivoLegacyStorageMigration.migrate(layout: layout)
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("SKILL.md"), encoding: .utf8), "现有课程")
        XCTAssertEqual(try String(contentsOf: source.appendingPathComponent("SKILL.md"), encoding: .utf8), "旧课程")
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("notes.md"), encoding: .utf8), "个人笔记")
        try NivoLegacyStorageMigration.migrate(layout: layout)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.appendingPathComponent("SKILL.md").path))
    }

    func testPartialFailureRetainsRemainingFilesAndCanRetry() throws {
        try write("文档", to: root.appendingPathComponent("MinisChat/shared/document.txt"))
        try write("记忆", to: root.appendingPathComponent("MinisChat/memory/USER.md"))
        let blocked = layout.applicationFiles.appendingPathComponent("memory")
        try write("阻止创建目录", to: blocked)
        XCTAssertThrowsError(try NivoLegacyStorageMigration.migrate(layout: layout))
        XCTAssertEqual(try String(contentsOf: layout.applicationFiles.appendingPathComponent("shared/document.txt"), encoding: .utf8), "文档")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("MinisChat/memory/USER.md").path))
        try FileManager.default.removeItem(at: blocked)
        try NivoLegacyStorageMigration.migrate(layout: layout)
        XCTAssertEqual(try String(contentsOf: layout.applicationFiles.appendingPathComponent("memory/USER.md"), encoding: .utf8), "记忆")
    }

    func testSharedLegacyFolderUsesActualSharedContainer() throws {
        let shared = root.appendingPathComponent("group")
        let sharedLayout = NivoStorageLayout(sharedContainer: shared, libraryDirectory: root)
        try write("共享文档", to: shared.appendingPathComponent("MinisShared/document.txt"))
        try NivoLegacyStorageMigration.migrate(layout: sharedLayout)
        XCTAssertEqual(try String(contentsOf: sharedLayout.applicationFiles.appendingPathComponent("shared/document.txt"), encoding: .utf8), "共享文档")
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.localContainer.path))
    }

    func testDirectoryLinksAreNotTraversedDuringMerge() throws {
        let outside = root.appendingPathComponent("external")
        let source = root.appendingPathComponent("MinisChat/skills/writing")
        let target = layout.applicationFiles.appendingPathComponent("skills/writing")
        try write("外部资料", to: outside.appendingPathComponent("notes.md"))
        try write("现有技能", to: target.appendingPathComponent("SKILL.md"))
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try FileManager.default.createSymbolicLink(at: source, withDestinationURL: outside)
        } catch {
            throw XCTSkip("当前系统未提供创建符号链接的权限")
        }
        try NivoLegacyStorageMigration.migrate(layout: layout)
        XCTAssertEqual(try String(contentsOf: outside.appendingPathComponent("notes.md"), encoding: .utf8), "外部资料")
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("notes.md").path))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: source.path)[.type] as? FileAttributeType, .typeSymbolicLink)
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
}
