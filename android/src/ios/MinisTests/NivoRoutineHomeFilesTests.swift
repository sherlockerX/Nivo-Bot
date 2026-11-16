import XCTest
@testable import Minis

/// 使用隔离的真实文件检查脚本恢复，不写入用户的home或正式备份。
final class NivoRoutineHomeFilesTests: XCTestCase {
    private struct Fixture {
        let root: URL
        var home: URL { root.appendingPathComponent("home") }
        var package: URL { root.appendingPathComponent("package") }
        var files: NivoRoutineHomeFiles { NivoRoutineHomeFiles(home: home) }
    }

    private func fixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let value = Fixture(root: root.resolvingSymlinksInPath())
        addTeardownBlock {
            do { try FileManager.default.removeItem(at: value.root) }
            catch { XCTFail("临时目录清理失败，保留现场：\(value.root.path)，\(error)") }
        }
        return value
    }

    private func write(_ data: Data, to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file)
    }

    private func blob(_ data: Data, path: String, fixture: Fixture) throws -> NivoRoutineHomeFiles.Entry {
        let source = fixture.root.appendingPathComponent("source")
        try write(data, to: source)
        let digest = try NivoRoutineHomeFiles.digest(source)
        let target = fixture.package.appendingPathComponent("blobs/" + String(digest.prefix(2)) + "/" + digest)
        try write(data, to: target)
        return .init(path: path, size: Int64(data.count), digest: digest)
    }

    private func restore(_ entries: [NivoRoutineHomeFiles.Entry], in fixture: Fixture) throws -> NivoRoutineHomeFiles.Restored {
        try fixture.files.restore(entries, expected: entries.map(\.path), packageRoot: fixture.package)
    }

    func testRestoresScriptUnicodeAndEmptyDirectoriesThenScansSameTree() throws {
        let value = try fixture()
        let content = Data("#!/bin/sh\necho '专注开始'\n".utf8)
        let script = try blob(content, path: "bin/提醒.sh", fixture: value)
        let entries: [NivoRoutineHomeFiles.Entry] = [script, .init(path: "empty", isDirectory: true), .init(path: "bin", isDirectory: true)]
        let report = try restore(entries, in: value)
        XCTAssertEqual(report.files, 1)
        XCTAssertEqual(report.bytes, Int64(content.count))
        XCTAssertEqual(try Data(contentsOf: value.home.appendingPathComponent(script.path)), content)
        XCTAssertEqual(try value.files.scan().map(\.path), entries.map(\.path).sorted())
        XCTAssertEqual(try restore(entries, in: value), .init())
    }

    func testKeepsLocalConflictAndRestoresUnrelatedScript() throws {
        let value = try fixture()
        let local = value.home.appendingPathComponent("bin/task.sh")
        try write(Data("my script".utf8), to: local)
        let incoming = try blob(Data("old script".utf8), path: "bin/task.sh", fixture: value)
        let other = try blob(Data("another".utf8), path: "other.sh", fixture: value)
        let result = try restore([incoming, other], in: value)
        XCTAssertEqual(result.conflicts, ["bin/task.sh"])
        XCTAssertEqual(result.files, 1)
        XCTAssertEqual(try String(contentsOf: local, encoding: .utf8), "my script")
    }

    func testParentFileConflictDoesNotReplaceExistingFileWithDirectory() throws {
        let value = try fixture()
        try write(Data("local".utf8), to: value.home.appendingPathComponent("bin"))
        let script = try blob(Data("new".utf8), path: "bin/task.sh", fixture: value)
        let result = try restore([.init(path: "bin", isDirectory: true), script], in: value)
        XCTAssertEqual(result.conflicts, ["bin", "bin/task.sh"])
        XCTAssertEqual(result.files, 0)
        XCTAssertEqual(try String(contentsOf: value.home.appendingPathComponent("bin"), encoding: .utf8), "local")
    }

    func testCorruptBlobAndWrongSizeCannotOccupyFinalPath() throws {
        let value = try fixture()
        let entry = try blob(Data("abc".utf8), path: "task.sh", fixture: value)
        var wrongSize = entry
        wrongSize.size += 1
        XCTAssertThrowsError(try restore([wrongSize], in: value))
        let digest = try XCTUnwrap(entry.digest)
        try Data("bad".utf8).write(to: value.package.appendingPathComponent("blobs/" + String(digest.prefix(2)) + "/" + digest))
        XCTAssertThrowsError(try restore([entry], in: value))
        XCTAssertFalse(FileManager.default.fileExists(atPath: value.home.appendingPathComponent("task.sh").path))
    }

    func testMissingBlobFailsWithoutClaimingRestoredFile() throws {
        let value = try fixture()
        let entry = NivoRoutineHomeFiles.Entry(path: "task.sh", size: 1, digest: String(repeating: "a", count: 64))
        XCTAssertThrowsError(try restore([entry], in: value))
        XCTAssertFalse(FileManager.default.fileExists(atPath: value.home.appendingPathComponent("task.sh").path))
    }

    func testFailedStagedCopyCleansTemporaryAndRetrySucceeds() throws {
        let value = try fixture()
        let entry = try blob(Data(repeating: 7, count: 2_000_000), path: "task.sh", fixture: value)
        XCTAssertThrowsError(try value.files.restore([entry], expected: [entry.path], packageRoot: value.package) { _ in
            throw CocoaError(.fileWriteOutOfSpace)
        })
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: value.home.path), [])
        XCTAssertEqual(try restore([entry], in: value).files, 1)
        XCTAssertEqual(try Data(contentsOf: value.home.appendingPathComponent(entry.path)).count, 2_000_000)
    }

    func testInvalidManifestRejectedBeforeCreatingHome() throws {
        let value = try fixture()
        let directory = NivoRoutineHomeFiles.Entry(path: "bin", isDirectory: true)
        XCTAssertThrowsError(try value.files.restore([directory, directory], expected: ["bin"], packageRoot: value.package))
        XCTAssertThrowsError(try value.files.restore([], expected: ["bin"], packageRoot: value.package))
        XCTAssertThrowsError(try value.files.restore([directory], expected: ["other"], packageRoot: value.package))
        XCTAssertFalse(FileManager.default.fileExists(atPath: value.home.path))
    }

    func testTraversalAndInvalidEntryMetadataRejectedBeforeWrites() throws {
        let value = try fixture()
        for path in ["../outside", "/absolute", "bin/../../outside", "C:/outside", "bin\\task", ".live-path"] {
            XCTAssertThrowsError(try restore([.init(path: path, isDirectory: true)], in: value), path)
        }
        let invalid: [NivoRoutineHomeFiles.Entry] = [
            .init(path: "a", size: 1, isDirectory: true),
            .init(path: "b", digest: String(repeating: "A", count: 64)),
            .init(path: "c", size: -1, digest: String(repeating: "a", count: 64)),
            .init(path: "d", digest: "abc"),
        ]
        for entry in invalid { XCTAssertThrowsError(try restore([entry], in: value)) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: value.home.path))
    }

    func testSkippedFilesRemainAbsentAndDoNotRequireBlob() throws {
        let value = try fixture()
        let result = try restore([.init(path: "oversize.bin", size: 99, isSkipped: true)], in: value)
        XCTAssertEqual(result.skipped, 1)
        XCTAssertEqual(result.files, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: value.home.path), [])
    }

    func testContentDigestMatchesKnownSHA256IncludingZeroByteFiles() throws {
        let value = try fixture()
        let entry = try blob(Data("abc".utf8), path: "task.sh", fixture: value)
        XCTAssertEqual(entry.digest, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        let empty = try blob(Data(), path: "empty.sh", fixture: value)
        XCTAssertEqual(empty.digest, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(try restore([empty], in: value).files, 1)
        XCTAssertEqual(try Data(contentsOf: value.home.appendingPathComponent(empty.path)), Data())
    }

    #if !os(Windows)
    func testHomeAndParentSymlinksCannotRedirectRestoredFiles() throws {
        let value = try fixture()
        let outside = value.root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: value.home, withDestinationURL: outside)
        let entry = try blob(Data("script".utf8), path: "task.sh", fixture: value)
        XCTAssertThrowsError(try restore([entry], in: value))
        try FileManager.default.removeItem(at: value.home)
        try FileManager.default.createDirectory(at: value.home, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: value.home.appendingPathComponent("bin"), withDestinationURL: outside)
        var nested = entry
        nested.path = "bin/task.sh"
        XCTAssertEqual(try restore([nested], in: value).conflicts, [nested.path])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), [])
    }

    func testScanDoesNotFollowDirectoryOrBrokenSymlinks() throws {
        let value = try fixture()
        let outside = value.root.appendingPathComponent("outside")
        try write(Data("private".utf8), to: outside.appendingPathComponent("secret"))
        try FileManager.default.createDirectory(at: value.home, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: value.home.appendingPathComponent("link"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: value.home.appendingPathComponent("broken"), withDestinationURL: outside.appendingPathComponent("missing"))
        let nodes = try value.files.scan()
        XCTAssertEqual(nodes.map(\.path), ["broken", "link"])
        XCTAssertTrue(nodes.allSatisfy { $0.kind == .typeSymbolicLink })
    }

    func testPackageBlobDirectorySymlinkIsRejected() throws {
        let value = try fixture()
        let entry = try blob(Data("script".utf8), path: "task.sh", fixture: value)
        let blobs = value.package.appendingPathComponent("blobs")
        let outside = value.root.appendingPathComponent("outside")
        try FileManager.default.moveItem(at: blobs, to: outside)
        try FileManager.default.createSymbolicLink(at: blobs, withDestinationURL: outside)
        XCTAssertThrowsError(try restore([entry], in: value))
        XCTAssertFalse(FileManager.default.fileExists(atPath: value.home.appendingPathComponent(entry.path).path))
    }
    #endif
}
