import XCTest
@testable import Minis

/// 验证生产写入队列的排队、错误和恢复，文件写入使用真实临时目录。
@MainActor
final class NivoProviderWriteQueueTests: XCTestCase {
    func testLaterSnapshotWaitsForEarlierJSONAndDatabaseWrites() async throws {
        let root = try directory()
        let json = root.appendingPathComponent("config.json")
        let mirror = root.appendingPathComponent("database-mirror")
        let gate = NivoProviderWriteTestGate()
        let queue = NivoProviderWriteQueue()
        queue.enqueue {
            try Data("first".utf8).write(to: json)
            await gate.wait()
            try Data("first".utf8).write(to: mirror)
        }
        queue.enqueue {
            try Data("second".utf8).write(to: json)
            try Data("second".utf8).write(to: mirror)
        }
        await gate.open()
        try await queue.waitUntilIdle()
        XCTAssertEqual(try String(contentsOf: json, encoding: .utf8), "second")
        XCTAssertEqual(try String(contentsOf: mirror, encoding: .utf8), "second")
    }

    func testWriteFailureReachesWaiterAndNextFullSnapshotCanRetry() async throws {
        let root = try directory()
        let queue = NivoProviderWriteQueue()
        queue.enqueue { throw CocoaError(.fileWriteOutOfSpace) }
        do {
            try await queue.waitUntilIdle()
            XCTFail("写盘失败不能变为成功")
        } catch { XCTAssertEqual((error as? CocoaError)?.code, .fileWriteOutOfSpace) }
        let target = root.appendingPathComponent("retry")
        queue.enqueue { try Data("retry".utf8).write(to: target) }
        try await queue.waitUntilIdle()
        XCTAssertEqual(try Data(contentsOf: target), Data("retry".utf8))
    }

    func testWaiterIncludesSnapshotEnqueuedWhileEarlierWriteIsRunning() async throws {
        let firstGate = NivoProviderWriteTestGate()
        let secondGate = NivoProviderWriteTestGate()
        let queue = NivoProviderWriteQueue()
        queue.enqueue { await firstGate.wait() }
        let waiter = Task { try await queue.waitUntilIdle() }
        await Task.yield()
        queue.enqueue {
            await secondGate.wait()
            throw CocoaError(.fileWriteNoPermission)
        }
        await firstGate.open()
        await secondGate.open()
        do {
            try await waiter.value
            XCTFail("等待者漏掉了新尾部的失败")
        } catch { XCTAssertEqual((error as? CocoaError)?.code, .fileWriteNoPermission) }
    }

    func testSuccessfulRollbackCanClearFailureWithoutReplayingFailedWrite() async throws {
        let queue = NivoProviderWriteQueue()
        queue.enqueue { throw CocoaError(.fileWriteOutOfSpace) }
        _ = try? await queue.waitUntilIdle()
        queue.didRestoreSnapshot()
        try await queue.waitUntilIdle()
    }

    func testRecoverySnapshotKnowsPriorWriteFailedBeforeItBegins() async throws {
        let root = try directory()
        let result = root.appendingPathComponent("retry-result")
        let queue = NivoProviderWriteQueue()
        queue.enqueue { throw CocoaError(.fileWriteOutOfSpace) }
        queue.enqueue { isRetry in
            try Data((isRetry ? "full-snapshot" : "incremental").utf8).write(to: result)
        }
        try await queue.waitUntilIdle()
        XCTAssertEqual(try String(contentsOf: result, encoding: .utf8), "full-snapshot")
        XCTAssertFalse(queue.hasFailedWrite)
    }

    func testObservedWriteFailureClearsAfterSuccessfulRetry() async throws {
        let queue = NivoProviderWriteQueue()
        queue.enqueue { throw CocoaError(.fileWriteNoPermission) }
        _ = try? await queue.waitUntilIdle()
        XCTAssertTrue(queue.hasFailedWrite)
        queue.enqueue {}
        try await queue.waitUntilIdle()
        XCTAssertFalse(queue.hasFailedWrite)
    }

    func testMirrorFailureCanBeIgnoredForRefreshButRemainsVisibleToBackup() async throws {
        let queue = NivoProviderWriteQueue()
        queue.enqueueMirror { throw CocoaError(.fileWriteNoPermission) }
        try await queue.waitUntilIdle(allowingMirrorFailure: true)
        XCTAssertTrue(queue.hasFailedWrite)
        do {
            try await queue.waitUntilIdle()
            XCTFail("备份不能把失败镜像当成已保存")
        } catch { XCTAssertEqual((error as? CocoaError)?.code, .fileWriteNoPermission) }
        queue.enqueueMirror {}
        try await queue.waitUntilIdle()
        XCTAssertFalse(queue.hasFailedWrite)
    }

    func testMirrorCannotHideConfigurationFailureEvenAcrossRepeatedMirrors() async throws {
        let root = try directory()
        let target = root.appendingPathComponent("must-not-write")
        let queue = NivoProviderWriteQueue()
        queue.enqueue { throw CocoaError(.fileWriteOutOfSpace) }
        queue.enqueueMirror { try Data("first".utf8).write(to: target) }
        queue.enqueueMirror { try Data("second".utf8).write(to: target) }
        do {
            try await queue.waitUntilIdle(allowingMirrorFailure: true)
            XCTFail("镜像不能覆盖未完成的完整配置保存")
        } catch { XCTAssertEqual((error as? CocoaError)?.code, .fileWriteOutOfSpace) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        queue.enqueue { isRetry in
            XCTAssertTrue(isRetry)
            try Data("recovered".utf8).write(to: target)
        }
        try await queue.waitUntilIdle()
        XCTAssertEqual(try Data(contentsOf: target), Data("recovered".utf8))
    }

    func testMirrorTolerantWaiterStillReportsConfigurationFailureQueuedLater() async throws {
        let gate = NivoProviderWriteTestGate()
        let queue = NivoProviderWriteQueue()
        queue.enqueueMirror {
            await gate.wait()
            throw CocoaError(.fileWriteNoPermission)
        }
        let waiter = Task { try await queue.waitUntilIdle(allowingMirrorFailure: true) }
        await Task.yield()
        queue.enqueue { throw CocoaError(.fileWriteOutOfSpace) }
        await gate.open()
        do {
            try await waiter.value
            XCTFail("等待期间新增的完整写入失败必须报告")
        } catch { XCTAssertEqual((error as? CocoaError)?.code, .fileWriteOutOfSpace) }
    }

    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("provider-queue-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return root
    }
}

/// 测试用确定性屏障，不用延时推测并发执行顺序。
private actor NivoProviderWriteTestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}
