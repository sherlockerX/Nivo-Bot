import XCTest
@testable import Minis

/// 队列使用真实临时文件验证崩溃恢复边界，测试不触碰聊天和正式课程。
final class NivoCoachArchiveOutboxTests: XCTestCase {
    private func files() throws -> NivoCoachArchiveFiles {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("outbox-" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock {
            do { try FileManager.default.removeItem(at: folder) }
            catch { XCTFail("临时目录清理失败，保留现场：\(folder.path)，\(error)") }
        }
        return NivoCoachArchiveFiles(directory: folder, writer: { data, url in try data.write(to: url, options: .atomic) })
    }

    private func entry() -> NivoCoachArchiveEntry {
        NivoCoachArchiveEntry(ownerKey: "owner", chatID: "chat", lessonID: "first", messageID: "row",
            role: "assistant", text: "A visible explanation", digest: String(repeating: "a", count: 64))
    }

    func testRetryPreservesFirstLessonAndIsolation() throws {
        let files = try files()
        let first = entry()
        try files.put(first)
        var retry = first
        retry.lessonID = "later"
        try files.put(retry)
        XCTAssertEqual(files.read(owner: "owner", chatID: "chat").entries, [first])
        XCTAssertTrue(files.read(owner: "other", chatID: "chat").entries.isEmpty)
        try files.remove(first)
        XCTAssertTrue(files.read(owner: "owner", chatID: "chat").entries.isEmpty)
    }

    func testChangedOriginalCannotReplacePendingSource() throws {
        let files = try files()
        let first = entry()
        try files.put(first)
        var changed = first
        changed.text = "Rewritten explanation"
        XCTAssertThrowsError(try files.put(changed))
        XCTAssertEqual(files.read(owner: "owner", chatID: "chat").entries, [first])
    }

    func testSignedOutLocalAccountCanArchiveWithoutBeingTreatedAsMissingOwner() throws {
        let files = try files()
        var local = entry()
        local.ownerKey = ""
        try files.put(local)
        XCTAssertEqual(files.read(owner: "", chatID: "chat").entries, [local])
        XCTAssertTrue(files.read(owner: "signed-in", chatID: "chat").entries.isEmpty)
    }

    func testCorruptEntryDoesNotHideHealthyPendingEntry() throws {
        let files = try files()
        let first = entry()
        try files.put(first)
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: files.directory, includingPropertiesForKeys: nil))
        let paths = enumerator.allObjects.compactMap { $0 as? URL }.filter { $0.pathExtension == "json" }
        let folder = try XCTUnwrap(paths.first).deletingLastPathComponent()
        try Data("broken".utf8).write(to: folder.appendingPathComponent("broken.json"))
        let result = files.read(owner: "owner", chatID: "chat")
        XCTAssertEqual(result.entries, [first])
        XCTAssertEqual(result.failures.count, 1)
    }
}
