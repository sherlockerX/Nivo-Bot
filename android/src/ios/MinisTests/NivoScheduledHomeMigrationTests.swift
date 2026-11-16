import XCTest
@testable import Minis

/// 使用真实隔离目录检查升级、中断和冲突，不对正式脚本目录执行迁移。
final class NivoScheduledHomeMigrationTests: XCTestCase {
    private struct Fixture {
        let root: URL
        var home: URL { root.appendingPathComponent("persistent/home") }
        var legacy: URL { root.appendingPathComponent("rootfs/var/minis/home") }
        var migration: NivoScheduledHomeMigration { NivoScheduledHomeMigration(home: home, legacyHome: legacy) }
        var archives: URL { home.appendingPathComponent(".legacy-home-migrations") }
    }

    private func fixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fixture = Fixture(root: root.resolvingSymlinksInPath())
        addTeardownBlock { try FileManager.default.removeItem(at: fixture.root) }
        return fixture
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func text(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }

    private func archive(_ fixture: Fixture) throws -> URL {
        try XCTUnwrap(FileManager.default.contentsOfDirectory(at: fixture.archives, includingPropertiesForKeys: nil).first)
            .appendingPathComponent("original")
    }

    func testMigrationPreservesOriginalAndCopiesNestedFiles() throws {
        let fixture = try fixture()
        try write("echo original", to: fixture.legacy.appendingPathComponent("bin/task.sh"))
        try write("data", to: fixture.legacy.appendingPathComponent("work/nested/data.txt"))
        let receipts = try fixture.migration.prepare()
        XCTAssertEqual(receipts.flatMap(\.copied).sorted(), ["bin/task.sh", "work/nested/data.txt"])
        XCTAssertEqual(try text(fixture.home.appendingPathComponent("bin/task.sh")), "echo original")
        XCTAssertEqual(try text(archive(fixture).appendingPathComponent("bin/task.sh")), "echo original")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.legacy.path))
    }

    func testConflictKeepsLocalFileAndArchivedOriginal() throws {
        let fixture = try fixture()
        try write("local", to: fixture.home.appendingPathComponent("bin/task.sh"))
        try write("old", to: fixture.legacy.appendingPathComponent("bin/task.sh"))
        try write("same", to: fixture.home.appendingPathComponent("same.txt"))
        try write("same", to: fixture.legacy.appendingPathComponent("same.txt"))
        let receipts = try fixture.migration.prepare()
        XCTAssertEqual(receipts.flatMap(\.conflicts), ["bin/task.sh"])
        XCTAssertEqual(try text(fixture.home.appendingPathComponent("bin/task.sh")), "local")
        XCTAssertEqual(try text(archive(fixture).appendingPathComponent("bin/task.sh")), "old")
    }

    func testInterruptionAfterArchiveRecoversOnNextPreparation() throws {
        let fixture = try fixture()
        try write("old", to: fixture.legacy.appendingPathComponent("bin/task.sh"))
        let interrupted = NivoScheduledHomeMigration(home: fixture.home, legacyHome: fixture.legacy) { checkpoint in
            if checkpoint == .archived { throw CocoaError(.fileWriteOutOfSpace) }
        }
        XCTAssertThrowsError(try interrupted.prepare())
        XCTAssertEqual(try text(archive(fixture).appendingPathComponent("bin/task.sh")), "old")
        XCTAssertEqual(try fixture.migration.prepare().flatMap(\.copied), ["bin/task.sh"])
        XCTAssertEqual(try text(fixture.home.appendingPathComponent("bin/task.sh")), "old")
    }

    func testFailedReceiptRetriesButCompletedMigrationDoesNotResurrectDeletedFiles() throws {
        let fixture = try fixture()
        let destination = fixture.home.appendingPathComponent("bin/task.sh")
        try write("old", to: fixture.legacy.appendingPathComponent("bin/task.sh"))
        let interrupted = NivoScheduledHomeMigration(home: fixture.home, legacyHome: fixture.legacy) { checkpoint in
            if checkpoint == .recording { throw CocoaError(.fileWriteOutOfSpace) }
        }
        XCTAssertThrowsError(try interrupted.prepare())
        XCTAssertEqual(try text(destination), "old")
        XCTAssertEqual(try fixture.migration.prepare().count, 1)
        try FileManager.default.removeItem(at: destination)
        XCTAssertTrue(try fixture.migration.prepare().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testRecreatedRootfsCreatesSeparateArchive() throws {
        let fixture = try fixture()
        try write("first", to: fixture.legacy.appendingPathComponent("bin/task.sh"))
        try fixture.migration.prepare()
        try write("second", to: fixture.legacy.appendingPathComponent("bin/task.sh"))
        let receipts = try fixture.migration.prepare()
        XCTAssertEqual(receipts.flatMap(\.conflicts), ["bin/task.sh"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: fixture.archives, includingPropertiesForKeys: nil).count, 2)
        XCTAssertEqual(try text(fixture.home.appendingPathComponent("bin/task.sh")), "first")
    }

    func testInterruptedFileCopyDoesNotOccupyFinalScriptPath() throws {
        let fixture = try fixture()
        try write("complete", to: fixture.legacy.appendingPathComponent("bin/task.sh"))
        let interrupted = NivoScheduledHomeMigration(home: fixture.home, legacyHome: fixture.legacy) { checkpoint in
            if checkpoint == .staged("bin/task.sh") { throw CocoaError(.fileWriteOutOfSpace) }
        }
        XCTAssertThrowsError(try interrupted.prepare())
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.home.appendingPathComponent("bin/task.sh").path))
        XCTAssertEqual(try fixture.migration.prepare().flatMap(\.copied), ["bin/task.sh"])
        XCTAssertEqual(try text(fixture.home.appendingPathComponent("bin/task.sh")), "complete")
    }

    func testUnexpectedLegacyFileIsNotDeleted() throws {
        let fixture = try fixture()
        try write("keep", to: fixture.legacy)
        XCTAssertThrowsError(try fixture.migration.prepare())
        XCTAssertEqual(try text(fixture.legacy), "keep")
    }

    #if !os(Windows)
    func testForeignSymlinkIsNotFollowedOrReplaced() throws {
        let fixture = try fixture()
        let foreign = fixture.root.appendingPathComponent("foreign")
        try write("keep", to: foreign.appendingPathComponent("bin/task.sh"))
        try FileManager.default.createDirectory(at: fixture.legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: fixture.legacy, withDestinationURL: foreign)
        XCTAssertThrowsError(try fixture.migration.prepare())
        XCTAssertEqual(try text(foreign.appendingPathComponent("bin/task.sh")), "keep")
    }

    func testLinkedFileIsArchivedButNeverCopiedIntoActiveBin() throws {
        let fixture = try fixture()
        let foreign = fixture.root.appendingPathComponent("foreign.sh")
        try write("keep", to: foreign)
        let linked = fixture.legacy.appendingPathComponent("bin/task.sh")
        try FileManager.default.createDirectory(at: linked.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: foreign)
        XCTAssertEqual(try fixture.migration.prepare().flatMap(\.skipped), ["bin/task.sh"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.home.appendingPathComponent("bin/task.sh").path))
    }
    #endif
}
