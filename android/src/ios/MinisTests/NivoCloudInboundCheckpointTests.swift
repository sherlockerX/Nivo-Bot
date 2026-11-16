import XCTest
@testable import Minis

/// 直接验证生产游标屏障及真实文件写入，不能用已收到事件代替已经应用事件。
final class NivoCloudInboundCheckpointTests: XCTestCase {
    func testBusyBatchKeepsOldCheckpointUntilEveryApplyFinishes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("checkpoint")
        try Data("old".utf8).write(to: url)
        let gate = NivoCloudInboundCheckpoint()
        let first = gate.begin()
        let second = gate.begin()
        XCTAssertFalse(try gate.persistIfSettled { try Data("new".utf8).write(to: url, options: .atomic) })
        gate.finish(first, succeeded: true)
        XCTAssertFalse(try gate.persistIfSettled { try Data("new".utf8).write(to: url, options: .atomic) })
        XCTAssertEqual(try Data(contentsOf: url), Data("old".utf8))
        gate.finish(second, succeeded: true)
        XCTAssertTrue(try gate.persistIfSettled { try Data("new".utf8).write(to: url, options: .atomic) })
        XCTAssertEqual(try Data(contentsOf: url), Data("new".utf8))
    }

    func testFailedOrCancelledApplyPreventsLaterBatchFromAdvancingCheckpoint() {
        let gate = NivoCloudInboundCheckpoint()
        let failed = gate.begin()
        gate.finish(failed, succeeded: false)
        let next = gate.begin()
        gate.finish(next, succeeded: true)
        XCTAssertFalse(gate.isBusy)
        XCTAssertTrue(gate.hasFailure)
        XCTAssertFalse(gate.persistIfSettled { XCTFail("未应用事件必须在重启后从旧游标重放") })
    }

    func testLateCallbackCannotReleaseAnotherBatchOrEraseFailure() {
        let gate = NivoCloudInboundCheckpoint()
        let old = gate.begin()
        gate.finish(old, succeeded: true)
        let current = gate.begin()
        gate.finish(old, succeeded: false)
        gate.finish(UUID(), succeeded: true)
        XCTAssertTrue(gate.isBusy)
        XCTAssertFalse(gate.hasFailure)
        gate.finish(current, succeeded: false)
        gate.finish(current, succeeded: true)
        XCTAssertTrue(gate.hasFailure)
    }

    func testWriteFailurePropagatesAndCanBeRetriedWithoutAnotherInboundBatch() throws {
        let gate = NivoCloudInboundCheckpoint()
        XCTAssertThrowsError(try gate.persistIfSettled { throw CocoaError(.fileWriteOutOfSpace) })
        XCTAssertFalse(gate.hasFailure)
        XCTAssertTrue(gate.persistIfSettled {})
    }
}
