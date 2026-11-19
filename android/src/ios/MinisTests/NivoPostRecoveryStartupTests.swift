import XCTest
@testable import Minis

/// 验证启动恢复与后续初始化的顺序，不以固定延时推测异步执行。
@MainActor
final class NivoPostRecoveryStartupTests: XCTestCase {
    func testFirstSuccessfulRecoveryRunsDraftCleanupBeforeModels() async {
        let startup = NivoPostRecoveryStartup()
        var steps: [String] = []
        await startup.run(waitForRecovery: { steps.append("recovered"); return true },
            recoverOAuthDrafts: { steps.append("drafts") }, prepareModels: { steps.append("models") })
        XCTAssertEqual(steps, ["recovered", "drafts", "models"])
    }

    func testFailedRecoveryLeavesInitializationAvailableForSuccessfulRetry() async {
        let startup = NivoPostRecoveryStartup()
        var steps: [String] = []
        await startup.run(waitForRecovery: { false }, recoverOAuthDrafts: { XCTFail() }, prepareModels: { XCTFail() })
        await startup.run(waitForRecovery: { true },
            recoverOAuthDrafts: { steps.append("drafts") }, prepareModels: { steps.append("models") })
        XCTAssertEqual(steps, ["drafts", "models"])
    }

    func testRecoveryNotificationWaitsUntilAccountLockIsReleased() async {
        let startup = NivoPostRecoveryStartup()
        let lock = NivoAccountTransitionLock()
        await lock.acquire()
        var steps: [String] = []
        var initialization: Task<Void, Never>?
        await withCheckedContinuation { (waiting: CheckedContinuation<Void, Never>) in
            initialization = Task { @MainActor in
                await startup.run(waitForRecovery: {
                    waiting.resume()
                    await lock.acquire()
                    lock.release()
                    return true
                }, recoverOAuthDrafts: { steps.append("drafts") }, prepareModels: { steps.append("models") })
            }
        }
        XCTAssertTrue(steps.isEmpty)
        lock.release()
        await initialization?.value
        XCTAssertEqual(steps, ["drafts", "models"])
    }

    func testConcurrentCompletionNotificationDoesNotRunInitializationTwice() async {
        let startup = NivoPostRecoveryStartup()
        let gate = StartupTestGate()
        var counts = (drafts: 0, models: 0)
        var first: Task<Void, Never>?
        await withCheckedContinuation { (arrived: CheckedContinuation<Void, Never>) in
            first = Task { @MainActor in
                await startup.run(waitForRecovery: {
                    arrived.resume()
                    await gate.wait()
                    return true
                }, recoverOAuthDrafts: { counts.drafts += 1 }, prepareModels: { counts.models += 1 })
            }
        }
        await startup.run(waitForRecovery: { XCTFail(); return true },
            recoverOAuthDrafts: { XCTFail() }, prepareModels: { XCTFail() })
        gate.open()
        await first?.value
        await startup.run(waitForRecovery: { XCTFail(); return true },
            recoverOAuthDrafts: { XCTFail() }, prepareModels: { XCTFail() })
        XCTAssertEqual(counts.drafts, 1)
        XCTAssertEqual(counts.models, 1)
    }

    func testNestedStartupNotificationReturnsWithoutWaitingOnItself() async {
        let startup = NivoPostRecoveryStartup()
        var hasReturnedFromNestedCall = false
        var hasPreparedModels = false
        await startup.run(waitForRecovery: { true }, recoverOAuthDrafts: {
            await startup.run(waitForRecovery: { XCTFail(); return true },
                recoverOAuthDrafts: { XCTFail() }, prepareModels: { XCTFail() })
            hasReturnedFromNestedCall = true
        }, prepareModels: { hasPreparedModels = true })
        XCTAssertTrue(hasReturnedFromNestedCall)
        XCTAssertTrue(hasPreparedModels)
    }

    func testLaterAppearanceDoesNotRepeatCompletedStartup() async {
        let startup = NivoPostRecoveryStartup()
        await startup.run(waitForRecovery: { true }, recoverOAuthDrafts: {}, prepareModels: {})
        await startup.run(waitForRecovery: { XCTFail(); return true },
            recoverOAuthDrafts: { XCTFail() }, prepareModels: { XCTFail() })
    }

    #if canImport(UIKit)
    func testApplicationRecoveryBarrierWaitsForTheActualAccountLease() async {
        await NivoPersonalBackupAccess.beginAccountChange()
        var hasResumed = false
        var waiter: Task<Void, Never>?
        await withCheckedContinuation { (arrived: CheckedContinuation<Void, Never>) in
            waiter = Task { @MainActor in
                arrived.resume()
                await NivoPersonalBackupAccess.waitForAccountTransitionToFinish()
                hasResumed = true
            }
        }
        XCTAssertFalse(hasResumed)
        NivoPersonalBackupAccess.endAccountChange()
        await waiter?.value
        XCTAssertTrue(hasResumed)
        XCTAssertFalse(NivoPersonalBackupAccess.hasAccountTransition)
    }
    #endif
}

/// 让测试明确控制初始化何时可以继续。
@MainActor
private final class StartupTestGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}
