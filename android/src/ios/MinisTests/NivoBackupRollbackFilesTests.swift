import XCTest
@testable import Minis

/// 以真实目录和失败注入验证回滚材料不被静默跳过或提前删除。
final class NivoBackupRollbackFilesTests: XCTestCase {
    private func root() throws -> URL {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = base.appendingPathComponent("rollback-test", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: base) }
        return root
    }

    func testDirectoryWithoutLivePathIsRejectedAndPreserved() throws {
        let root = try root()
        let saved = root.appendingPathComponent("personal_data-0")
        try FileManager.default.createDirectory(at: saved, withIntermediateDirectories: true)
        try Data("original".utf8).write(to: saved.appendingPathComponent("state.json"))
        XCTAssertThrowsError(try NivoBackupRollbackFiles.entries(in: root, expectedNames: ["personal_data-0"]))
        XCTAssertEqual(try Data(contentsOf: saved.appendingPathComponent("state.json")), Data("original".utf8))
    }

    func testFilePayloadAndSidecarProduceOneRestorationEntry() throws {
        let root = try root()
        let payload = root.appendingPathComponent("config.json")
        let sidecar = root.appendingPathComponent("config.json.live-path-of")
        let live = root.deletingLastPathComponent().appendingPathComponent("live/config.json")
        try Data("original".utf8).write(to: payload)
        try Data(live.path.utf8).write(to: sidecar)
        let entries = try NivoBackupRollbackFiles.entries(in: root, expectedNames: ["config.json", "config.json.live-path-of"])
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.kind, .file)
        XCTAssertEqual(entries.first?.live.path, live.path)
        XCTAssertEqual(try Data(contentsOf: payload), Data("original".utf8))
    }

    func testMissingPayloadMissingManifestEntryAndUnknownFileAllFail() throws {
        let root = try root()
        let live = root.deletingLastPathComponent().appendingPathComponent("live/config.json")
        try Data(live.path.utf8).write(to: root.appendingPathComponent("config.json.live-path-of"))
        XCTAssertThrowsError(try NivoBackupRollbackFiles.entries(in: root, expectedNames: ["config.json.live-path-of"]))
        try Data("original".utf8).write(to: root.appendingPathComponent("config.json"))
        XCTAssertThrowsError(try NivoBackupRollbackFiles.entries(in: root, expectedNames: ["config.json", "config.json.live-path-of", "missing"]))
        try Data("unknown".utf8).write(to: root.appendingPathComponent("unknown"))
        XCTAssertThrowsError(try NivoBackupRollbackFiles.entries(in: root, expectedNames: nil))
    }

    func testAbsentTargetsAreKeptDistinctFromFiles() throws {
        let root = try root()
        let live = root.deletingLastPathComponent().appendingPathComponent("new.json")
        let sidecar = "new.json.absent-path-of"
        try Data(live.path.utf8).write(to: root.appendingPathComponent(sidecar))
        let entries = try NivoBackupRollbackFiles.entries(in: root, expectedNames: [sidecar])
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.kind, .absent)
        XCTAssertFalse(FileManager.default.fileExists(atPath: live.path))
    }

    func testBoundRunDoesNotReadAnotherRunAndLegacyAmbiguityFails() throws {
        let root = try root()
        var marker = NivoBackupRecoveryState.Marker(backupId: "b", startedAt: Date(), categories: [],
            runId: "test", snapshotNames: [])
        let stale = root.deletingLastPathComponent().appendingPathComponent("rollback-stale")
        XCTAssertEqual(try NivoBackupRollbackFiles.recoveryRoot(marker: marker, roots: [stale, root]), root)
        XCTAssertThrowsError(try NivoBackupRollbackFiles.recoveryRoot(marker: marker, roots: [stale]))
        marker.runId = nil
        marker.snapshotNames = nil
        XCTAssertThrowsError(try NivoBackupRollbackFiles.recoveryRoot(marker: marker, roots: [stale, root]))
        XCTAssertThrowsError(try NivoBackupRollbackFiles.entries(in: root, expectedNames: nil))
        XCTAssertTrue(try NivoBackupRollbackFiles.entries(in: root, expectedNames: []).isEmpty)
    }

    func testMarkerDeletionFailurePreservesEverySnapshot() throws {
        let root = try root()
        let marker = root.deletingLastPathComponent().appendingPathComponent("in-progress.json")
        let payload = root.appendingPathComponent("original")
        try Data("marker".utf8).write(to: marker)
        try Data("original".utf8).write(to: payload)
        var attempted: [URL] = []
        XCTAssertThrowsError(try NivoBackupRollbackFiles.finish(marker: marker, root: root) { url in
            attempted.append(url)
            throw CocoaError(.fileWriteNoPermission)
        })
        XCTAssertEqual(attempted, [marker])
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertEqual(try Data(contentsOf: payload), Data("original".utf8))
    }

    func testSnapshotCleanupFailureIsReportedAfterMarkerWasRemoved() throws {
        let root = try root()
        let marker = root.deletingLastPathComponent().appendingPathComponent("in-progress.json")
        try Data("marker".utf8).write(to: marker)
        XCTAssertThrowsError(try NivoBackupRollbackFiles.finish(marker: marker, root: root) { url in
            if url == root { throw CocoaError(.fileWriteNoPermission) }
            try FileManager.default.removeItem(at: url)
        })
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
    }

    func testRelativeAndSelfReferencingTargetsAreRejected() throws {
        let root = try root()
        let sidecar = root.appendingPathComponent("new.absent-path-of")
        for value in ["../elsewhere", root.path, root.appendingPathComponent("victim").path] {
            try Data(value.utf8).write(to: sidecar)
            XCTAssertThrowsError(try NivoBackupRollbackFiles.entries(in: root, expectedNames: [sidecar.lastPathComponent]), value)
        }
    }
}
