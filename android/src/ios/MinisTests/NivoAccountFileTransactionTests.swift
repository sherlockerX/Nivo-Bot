import XCTest
@testable import Minis

/// 在隔离临时目录真实复制和恢复资料，故障注入只决定在哪个边界中断。
final class NivoAccountFileTransactionTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let slots: [NivoAccountFileTransaction.Slot]
        var files: NivoAccountFileTransaction { NivoAccountFileTransaction(root: root, slots: slots) }
    }

    private func fixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let actual = root.resolvingSymlinksInPath()
        addTeardownBlock {
            do { try FileManager.default.removeItem(at: actual) }
            catch { XCTFail("隔离测试目录清理失败，保留现场\(actual.path)：\(error)") }
        }
        let slots = ["memory", "goals.json"].map { NivoAccountFileTransaction.Slot(name: $0, live: actual.appendingPathComponent("live/" + $0)) }
        let fixture = Fixture(root: actual, slots: slots)
        try write("old memory", to: slots[0].live.appendingPathComponent("USER.md"))
        try write("old goals", to: slots[1].live)
        let target = fixture.files.archive(for: "target")
        try write("new memory", to: target.appendingPathComponent("memory/USER.md"))
        try write("new goals", to: target.appendingPathComponent("goals.json"))
        return fixture
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func prepare(_ files: NivoAccountFileTransaction, keep: Bool = true) throws {
        let defaults = try PropertyListSerialization.data(fromPropertyList: ["test": "source"], format: .binary, options: 0)
        _ = try files.prepare(source: "source", target: "target", keepSource: keep,
            sourceDefaults: defaults, targetIdentity: Data("identity".utf8))
    }

    func testSnapshotFailurePreservesActiveAndBothArchives() throws {
        let fixture = try fixture()
        let archived = fixture.files.archive(for: "source").appendingPathComponent("memory/USER.md")
        try write("previous archive", to: archived)
        let failing = NivoAccountFileTransaction(root: fixture.root, slots: fixture.slots) { checkpoint in
            if checkpoint == .snapshot("goals.json") { throw CocoaError(.fileWriteOutOfSpace) }
        }
        XCTAssertThrowsError(try prepare(failing))
        XCTAssertEqual(try String(contentsOf: fixture.slots[0].live.appendingPathComponent("USER.md"), encoding: .utf8), "old memory")
        XCTAssertEqual(try String(contentsOf: archived, encoding: .utf8), "previous archive")
        XCTAssertEqual(try String(contentsOf: fixture.files.archive(for: "target").appendingPathComponent("goals.json"), encoding: .utf8), "new goals")
        XCTAssertNil(try fixture.files.load())
    }

    func testPartialInstallRollsBackAfterProcessRestart() throws {
        let fixture = try fixture()
        try prepare(fixture.files)
        let failing = NivoAccountFileTransaction(root: fixture.root, slots: fixture.slots) { checkpoint in
            if checkpoint == .install("goals.json") { throw CocoaError(.fileWriteOutOfSpace) }
        }
        XCTAssertThrowsError(try failing.installTarget())
        XCTAssertEqual(try String(contentsOf: fixture.slots[0].live.appendingPathComponent("USER.md"), encoding: .utf8), "new memory")
        _ = try fixture.files.recoverFiles(useTarget: false)
        XCTAssertEqual(try String(contentsOf: fixture.slots[0].live.appendingPathComponent("USER.md"), encoding: .utf8), "old memory")
        XCTAssertEqual(try String(contentsOf: fixture.slots[1].live, encoding: .utf8), "old goals")
        try fixture.files.finish()
        XCTAssertNil(try fixture.files.load())
    }

    func testCommittedIdentityCompletesAndArchivesExactPreviousData() throws {
        let fixture = try fixture()
        try prepare(fixture.files)
        try fixture.files.installTarget()
        // 模拟密钥已提交、文件日志尚未更新时断电，宿主通过密钥摘要判定继续目标身份。
        _ = try fixture.files.recoverFiles(useTarget: true)
        try fixture.files.settleArchive()
        XCTAssertEqual(try String(contentsOf: fixture.files.archive(for: "source").appendingPathComponent("goals.json"), encoding: .utf8), "old goals")
        XCTAssertEqual(try String(contentsOf: fixture.slots[1].live, encoding: .utf8), "new goals")
        let defaults = try PropertyListSerialization.propertyList(from: fixture.files.defaults(useTarget: false), options: [], format: nil) as? [String: String]
        XCTAssertEqual(defaults?["test"], "source")
        try fixture.files.finish()
        XCTAssertNil(try fixture.files.load())
    }

    func testDeletionIsDeferredUntilIdentityCommit() throws {
        let fixture = try fixture()
        let archive = fixture.files.archive(for: "source").appendingPathComponent("goals.json")
        try write("previous", to: archive)
        try prepare(fixture.files, keep: false)
        try fixture.files.installTarget()
        XCTAssertThrowsError(try fixture.files.settleArchive())
        XCTAssertTrue(FileManager.default.fileExists(atPath: archive.path))
        try fixture.files.markCommitted()
        try fixture.files.settleArchive()
        XCTAssertFalse(FileManager.default.fileExists(atPath: archive.path))
        try fixture.files.finish()
    }

    func testCorruptTargetDefaultsCannotReplaceCurrentData() throws {
        let fixture = try fixture()
        try write("bad plist", to: fixture.files.archive(for: "target").appendingPathComponent("defaults.plist"))
        XCTAssertThrowsError(try prepare(fixture.files))
        XCTAssertEqual(try String(contentsOf: fixture.slots[1].live, encoding: .utf8), "old goals")
        XCTAssertNil(try fixture.files.load())
    }

    func testMissingSnapshotCannotBeMistakenForEmptyAccount() throws {
        let fixture = try fixture()
        try prepare(fixture.files)
        try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("pending-account-switch/target/goals.json"))
        XCTAssertThrowsError(try fixture.files.installTarget())
        XCTAssertEqual(try String(contentsOf: fixture.slots[0].live.appendingPathComponent("USER.md"), encoding: .utf8), "old memory")
    }

    func testArchiveFailureKeepsRecoveryJournalForRetry() throws {
        let fixture = try fixture()
        try prepare(fixture.files)
        try fixture.files.installTarget()
        try fixture.files.markCommitted()
        let failing = NivoAccountFileTransaction(root: fixture.root, slots: fixture.slots) { checkpoint in
            if checkpoint == .archive { throw CocoaError(.fileWriteOutOfSpace) }
        }
        XCTAssertThrowsError(try failing.settleArchive())
        XCTAssertEqual(try fixture.files.load()?.phase, .committed)
        try fixture.files.settleArchive()
        try fixture.files.finish()
        XCTAssertEqual(try String(contentsOf: fixture.slots[1].live, encoding: .utf8), "new goals")
    }

    func testFirstSignInStartsEmptyAndKeepsPreviousAccountArchive() throws {
        let fixture = try fixture()
        let defaults = try PropertyListSerialization.data(fromPropertyList: [String: String](), format: .binary, options: 0)
        _ = try fixture.files.prepare(source: "source", target: "fresh", keepSource: true,
            sourceDefaults: defaults, targetIdentity: Data())
        try fixture.files.installTarget()
        for slot in fixture.slots { XCTAssertFalse(FileManager.default.fileExists(atPath: slot.live.path)) }
        try fixture.files.markCommitted()
        try fixture.files.settleArchive()
        XCTAssertEqual(try String(contentsOf: fixture.files.archive(for: "source").appendingPathComponent("goals.json"), encoding: .utf8), "old goals")
        try fixture.files.finish()
    }

    func testRollbackRemovesFilesThatDidNotExistForSource() throws {
        let fixture = try fixture()
        try FileManager.default.removeItem(at: fixture.slots[1].live)
        try prepare(fixture.files)
        try fixture.files.installTarget()
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.slots[1].live.path))
        _ = try fixture.files.recoverFiles(useTarget: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.slots[1].live.path))
        XCTAssertEqual(try String(contentsOf: fixture.slots[0].live.appendingPathComponent("USER.md"), encoding: .utf8), "old memory")
        try fixture.files.finish()
    }

    func testCleanupFailureRetainsJournalWithoutReinstallingPartialSnapshots() throws {
        let fixture = try fixture()
        try prepare(fixture.files, keep: false)
        try fixture.files.installTarget()
        try fixture.files.markCommitted()
        try fixture.files.settleArchive()
        let failing = NivoAccountFileTransaction(root: fixture.root, slots: fixture.slots) { checkpoint in
            if checkpoint == .cleanup { throw CocoaError(.fileWriteNoPermission) }
        }
        XCTAssertThrowsError(try failing.finish())
        XCTAssertEqual(try fixture.files.load()?.phase, .settled)
        // 模拟清理中断：source已经删除。恢复只继续清理，不能重新安装已不存在的快照。
        try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("pending-account-switch/source"))
        _ = try fixture.files.recoverFiles(useTarget: true)
        XCTAssertEqual(try String(contentsOf: fixture.slots[1].live, encoding: .utf8), "new goals")
        try fixture.files.finish()
        XCTAssertNil(try fixture.files.load())
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("pending-account-switch").path))
    }
}
