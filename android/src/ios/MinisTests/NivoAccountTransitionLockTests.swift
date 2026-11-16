import XCTest
@testable import Minis

/// 用明确的到达信号验证身份切换独占，不以sleep推测调度先后。
@MainActor
final class NivoAccountTransitionLockTests: XCTestCase {
    func testWaitingTransitionCannotEnterBeforeCurrentOneFinishes() async {
        let lock = NivoAccountTransitionLock()
        await lock.acquire()
        var hasEntered = false
        var queued: Task<Void, Never>?
        await withCheckedContinuation { (arrived: CheckedContinuation<Void, Never>) in
            queued = Task { @MainActor in
                arrived.resume()
                await lock.acquire()
                hasEntered = true
                lock.release()
            }
        }
        XCTAssertFalse(hasEntered)
        lock.release()
        await queued?.value
        XCTAssertTrue(hasEntered)
        // 上一位释放后，后续身份切换仍能取得独占权。
        await lock.acquire()
        lock.release()
    }

    func testCancelledWaiterStillFinishesItsCleanupAndReleasesLock() async {
        let lock = NivoAccountTransitionLock()
        await lock.acquire()
        var hasCleaned = false
        var queued: Task<Void, Never>?
        await withCheckedContinuation { (arrived: CheckedContinuation<Void, Never>) in
            queued = Task { @MainActor in
                arrived.resume()
                await lock.acquire()
                defer { lock.release() }
                hasCleaned = true
            }
        }
        queued?.cancel()
        XCTAssertFalse(hasCleaned)
        lock.release()
        await queued?.value
        XCTAssertTrue(hasCleaned)
        await lock.acquire()
        lock.release()
    }
}
