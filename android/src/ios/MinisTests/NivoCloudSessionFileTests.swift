import XCTest
@testable import Minis

/// 使用独立真实文件验证云端附件失败保留、重放、路径和修改时间。
final class NivoCloudSessionFileTests: XCTestCase {
    func testReplacesAtomicallyAndPreservesRemoteModificationTime() throws {
        try fixture { root, asset, target in
            try write("原文件", to: target, at: 1)
            try write("新文件", to: asset, at: 20)
            XCTAssertEqual(try NivoCloudSessionFile.apply(input(asset, at: 10), root: root), .applied)
            XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "新文件")
            let attributes = try FileManager.default.attributesOfItem(atPath: target.path)
            XCTAssertEqual(try XCTUnwrap(attributes[.modificationDate] as? Date).timeIntervalSince1970, 10, accuracy: 0.01)
            XCTAssertEqual(try NivoCloudSessionFile.apply(input(asset, at: 10), root: root), .keptLocal)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.deletingLastPathComponent().path), ["note.txt"])
        }
    }

    func testMissingAndTruncatedAssetPreserveOriginal() throws {
        try fixture { root, asset, target in
            try write("原文件", to: target, at: 1)
            XCTAssertThrowsError(try NivoCloudSessionFile.apply(input(asset, at: 10), root: root))
            try write("短文件", to: asset, at: 2)
            let record = NivoCloudSessionFile.Incoming(sessionID: "chat", relativePath: "workspace/note.txt",
                asset: asset, expectedSize: 200, updatedAt: Date(timeIntervalSince1970: 10))
            XCTAssertThrowsError(try NivoCloudSessionFile.apply(record, root: root))
            XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "原文件")
        }
    }

    func testFailureAfterStagingDoesNotRemoveOriginalAndCleansTemporaryFile() throws {
        try fixture { root, asset, target in
            try write("原文件", to: target, at: 1)
            try write("替换", to: asset, at: 2)
            XCTAssertThrowsError(try NivoCloudSessionFile.apply(input(asset, at: 10), root: root) { _ in
                throw CocoaError(.fileWriteOutOfSpace)
            })
            XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "原文件")
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.deletingLastPathComponent().path), ["note.txt"])
        }
    }

    func testMissingStagedFileCannotDestroyDestination() throws {
        try fixture { root, asset, target in
            try write("原文件", to: target, at: 1)
            try write("替换", to: asset, at: 2)
            XCTAssertThrowsError(try NivoCloudSessionFile.apply(input(asset, at: 10), root: root) {
                try FileManager.default.removeItem(at: $0)
            })
            XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "原文件")
        }
    }

    func testNewerLocalEditWithinFiveSecondsIsPreserved() throws {
        try fixture { root, asset, target in
            try write("本机新修改", to: target, at: 12)
            try write("旧云端", to: asset, at: 1)
            XCTAssertEqual(try NivoCloudSessionFile.apply(input(asset, at: 10), root: root), .keptLocal)
            XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "本机新修改")
        }
    }

    func testLocalEditDuringStagingIsNotOverwritten() throws {
        try fixture { root, asset, target in
            try write("原始", to: target, at: 1)
            try write("云端", to: asset, at: 2)
            XCTAssertThrowsError(try NivoCloudSessionFile.apply(input(asset, at: 10), root: root) { _ in
                try self.write("正在编辑的新版本", to: target, at: 20)
            }) { XCTAssertEqual($0 as? NivoCloudSessionFileError, .destinationChanged) }
            XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "正在编辑的新版本")
        }
    }

    func testTraversalAbsolutePathsAndAlternateSeparatorsAreRejected() throws {
        for path in ["../escape", "/tmp/file", "workspace/../file", "workspace//file", "workspace/", "workspace\\file", "C:/file", "file\0.txt"] {
            XCTAssertThrowsError(try NivoCloudSessionFile.pathComponents(sessionID: "chat", relativePath: path))
        }
        for identifier in ["..", "/tmp", "a/b", "a\\b", "a:b", ""] {
            XCTAssertThrowsError(try NivoCloudSessionFile.pathComponents(sessionID: identifier, relativePath: "workspace/file"))
        }
        XCTAssertEqual(try NivoCloudSessionFile.pathComponents(sessionID: "会话", relativePath: "workspace/读书笔记.md"),
                       ["会话", "workspace", "读书笔记.md"])
    }

    func testDirectoriesCannotBeAcceptedAsAssetOrOverwrittenAsFile() throws {
        try fixture { root, asset, target in
            try FileManager.default.createDirectory(at: asset, withIntermediateDirectories: true)
            XCTAssertThrowsError(try NivoCloudSessionFile.apply(input(asset, at: 10), root: root))
            try FileManager.default.removeItem(at: asset)
            try write("附件", to: asset, at: 1)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            let child = target.appendingPathComponent("keep")
            try Data([1]).write(to: child)
            XCTAssertThrowsError(try NivoCloudSessionFile.apply(input(asset, at: 10), root: root))
            XCTAssertEqual(try Data(contentsOf: child), Data([1]))
        }
    }

    func testOversizedAssetIsRejectedAndEmptyFileCanBeCreated() throws {
        try fixture { root, asset, target in
            try Data(repeating: 1, count: 10).write(to: asset)
            XCTAssertThrowsError(try NivoCloudSessionFile.apply(input(asset, at: 10), root: root, maximumBytes: 9))
            XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
            try Data().write(to: asset)
            XCTAssertEqual(try NivoCloudSessionFile.apply(input(asset, at: 10), root: root), .applied)
            XCTAssertEqual(try Data(contentsOf: target), Data())
        }
    }

    func testOutgoingFileLookupRejectsTraversalAndDoesNotCreateMissingPaths() throws {
        try fixture { root, _, target in
            XCTAssertNil(try NivoCloudSessionFile.existingFile(root: root, sessionID: "chat", relativePath: "workspace/note.txt"))
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
            try write("文件", to: target, at: 1)
            XCTAssertEqual(try NivoCloudSessionFile.existingFile(root: root, sessionID: "chat", relativePath: "workspace/note.txt"), target)
            XCTAssertThrowsError(try NivoCloudSessionFile.existingFile(root: root, sessionID: "chat", relativePath: "../outside"))
        }
    }

    func testAlreadyCancelledReceiveDoesNotCreateOrReplaceFile() async throws {
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let asset = temporary.appendingPathComponent("asset")
        try Data("新附件".utf8).write(to: asset)
        let incoming = input(asset, at: 10)
        let root = temporary.appendingPathComponent("sessions")
        let worker = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await NivoCloudSessionFile.receive(incoming, root: root)
        }
        do { _ = try await worker.value; XCTFail("已取消的接收必须失败") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        try FileManager.default.removeItem(at: temporary)
    }

    #if !os(Windows)
    func testSymbolicLinkAncestorAndTargetCannotWriteOutsideSessionRoot() throws {
        try fixture { root, asset, target in
            try write("新文件", to: asset, at: 1)
            let outside = root.deletingLastPathComponent().appendingPathComponent("outside")
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.removeItem(at: target.deletingLastPathComponent())
            try FileManager.default.createSymbolicLink(at: target.deletingLastPathComponent(), withDestinationURL: outside)
            XCTAssertThrowsError(try NivoCloudSessionFile.apply(input(asset, at: 10), root: root))
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
            try FileManager.default.removeItem(at: target.deletingLastPathComponent())
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let original = outside.appendingPathComponent("original")
            try write("保留", to: original, at: 1)
            try FileManager.default.createSymbolicLink(at: target, withDestinationURL: original)
            XCTAssertThrowsError(try NivoCloudSessionFile.apply(input(asset, at: 10), root: root))
            XCTAssertThrowsError(try NivoCloudSessionFile.existingFile(root: root, sessionID: "chat", relativePath: "workspace/note.txt"))
            XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "保留")
        }
    }
    #endif

    private func input(_ asset: URL, at timestamp: Double) -> NivoCloudSessionFile.Incoming {
        .init(sessionID: "chat", relativePath: "workspace/note.txt", asset: asset, expectedSize: nil,
            updatedAt: Date(timeIntervalSince1970: timestamp))
    }

    private func write(_ text: String, to url: URL, at timestamp: Double) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: timestamp)], ofItemAtPath: url.path)
    }

    private func fixture(_ body: (URL, URL, URL) throws -> Void) throws {
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let root = temporary.appendingPathComponent("sessions")
        try body(root, temporary.appendingPathComponent("asset"), root.appendingPathComponent("chat/workspace/note.txt"))
        // 通过后严格清理，失败时保留现场，不把清理失败伪装成通过。
        try FileManager.default.removeItem(at: temporary)
    }
}
