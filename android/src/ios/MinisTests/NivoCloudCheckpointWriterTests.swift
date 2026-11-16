import XCTest
@testable import Minis

/// 使用真实状态文件验证引擎重置、候选替换和落盘失败的生命周期。
final class NivoCloudCheckpointWriterTests: XCTestCase {
    private func stateURL() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return root.appendingPathComponent("checkpoint")
    }

    @MainActor
    func testResetCannotResurrectDeletedStateOrRunSavedCallback() async throws {
        let url = try stateURL()
        try Data("old".utf8).write(to: url)
        let checkpoint = NivoCloudInboundCheckpoint()
        let token = checkpoint.begin()
        let writer = NivoCloudCheckpointWriter(checkpoint: checkpoint)
        let pending = writer.schedule(data: Data("stale".utf8), to: url,
            onSaved: { XCTFail("重置之后旧候选不能完成") }, onFailure: { _ in XCTFail("取消不应报告磁盘错误") })
        await Task.yield()
        writer.invalidate(url)
        try FileManager.default.removeItem(at: url)
        checkpoint.finish(token, succeeded: true)
        await pending.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    @MainActor
    func testNewCandidateSurvivesCancellationOfOldCandidate() async throws {
        let url = try stateURL()
        let checkpoint = NivoCloudInboundCheckpoint()
        let token = checkpoint.begin()
        let writer = NivoCloudCheckpointWriter(checkpoint: checkpoint)
        let old = writer.schedule(data: Data("old".utf8), to: url,
            onSaved: { XCTFail("旧候选已被替换") }, onFailure: { _ in XCTFail("旧候选应取消") })
        var didSave = false
        let new = writer.schedule(data: Data("new".utf8), to: url,
            onSaved: { didSave = true }, onFailure: { _ in XCTFail("新候选应成功") })
        await old.value
        checkpoint.finish(token, succeeded: true)
        await new.value
        XCTAssertTrue(didSave)
        XCTAssertEqual(try Data(contentsOf: url), Data("new".utf8))
    }

    @MainActor
    func testFailedInboundLeavesLastGoodState() async throws {
        let url = try stateURL()
        try Data("good".utf8).write(to: url)
        let checkpoint = NivoCloudInboundCheckpoint()
        let token = checkpoint.begin()
        checkpoint.finish(token, succeeded: false)
        let writer = NivoCloudCheckpointWriter(checkpoint: checkpoint)
        await writer.schedule(data: Data("bad".utf8), to: url,
            onSaved: { XCTFail("未应用的批次不能推进游标") }, onFailure: { _ in XCTFail("不是磁盘错误") }).value
        XCTAssertEqual(try Data(contentsOf: url), Data("good".utf8))
    }

    @MainActor
    func testDiskFailureIsReportedAndDoesNotInvokeSavedCallback() async throws {
        let url = try stateURL().appendingPathComponent("missing-parent/checkpoint")
        let writer = NivoCloudCheckpointWriter(checkpoint: NivoCloudInboundCheckpoint())
        var didFail = false
        await writer.schedule(data: Data("state".utf8), to: url,
            onSaved: { XCTFail("写盘失败不能更新内存游标") }, onFailure: { _ in didFail = true }).value
        XCTAssertTrue(didFail)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}
