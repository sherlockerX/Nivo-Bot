import XCTest
@testable import Minis

/// 直接驱动生产进程交接器，覆盖取消、超时与原生回调的交错顺序。
@MainActor
final class NivoScheduledProcessWaiterTests: XCTestCase {
    func testCancellationBeforeContinuationPreventsLaunch() async {
        let terminations = Terminations()
        let waiter = NivoScheduledProcessWaiter { terminations.append($0) }
        waiter.cancel()
        do {
            _ = try await withCheckedThrowingContinuation { waiter.start($0, timeout: 60) }
            XCTFail("取消后不能交付成功结果")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(waiter.beginLaunch())
        XCTAssertEqual(terminations.values, [])
    }

    func testCancellationDuringLaunchWinsOverLaterTimeoutAndTerminatesOnce() async {
        let terminations = Terminations()
        let waiter = NivoScheduledProcessWaiter { terminations.append($0) }
        do {
            _ = try await withCheckedThrowingContinuation { continuation in
                waiter.start(continuation, timeout: 60)
                XCTAssertTrue(waiter.beginLaunch())
                waiter.cancel()
                waiter.timeoutReached()
                XCTAssertEqual(terminations.values, [])
                waiter.didLaunch(44)
                waiter.complete(result())
                waiter.cancel()
            }
            XCTFail("后到的超时不能覆盖用户取消")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(terminations.values, [44])
    }

    func testCallbackBeforePIDHandoffDeliversFirstResultWithoutKillingExitedProcess() async throws {
        let terminations = Terminations()
        let waiter = NivoScheduledProcessWaiter { terminations.append($0) }
        let outcome = try await withCheckedThrowingContinuation { continuation in
            waiter.start(continuation, timeout: 60)
            XCTAssertTrue(waiter.beginLaunch())
            waiter.complete(result())
            waiter.didLaunch(45)
            waiter.complete(result(code: 7))
            waiter.cancel()
        }
        XCTAssertEqual(outcome.exitCode, 0)
        XCTAssertEqual(outcome.stdout, "saved output")
        XCTAssertEqual(terminations.values, [])
    }

    func testTimeoutAfterLaunchTerminatesBeforeReturningAndIgnoresLateSuccess() async throws {
        let terminations = Terminations()
        let waiter = NivoScheduledProcessWaiter { terminations.append($0) }
        let outcome = try await withCheckedThrowingContinuation { continuation in
            waiter.start(continuation, timeout: 60)
            XCTAssertTrue(waiter.beginLaunch())
            waiter.didLaunch(46)
            waiter.timeoutReached()
            waiter.complete(result())
        }
        XCTAssertTrue(outcome.timedOut)
        XCTAssertEqual(outcome.exitCode, 124)
        XCTAssertEqual(outcome.stdout, "saved output", "超时也必须保留原生读取器已经确认的输出")
        XCTAssertEqual(outcome.stdoutBytes, 12)
        XCTAssertEqual(terminations.values, [46])
    }

    func testCancellationDuringLaunchDoesNotRestartOrDropNativeCompletion() async {
        let terminations = Terminations()
        let waiter = NivoScheduledProcessWaiter { terminations.append($0) }
        do {
            _ = try await withCheckedThrowingContinuation { continuation in
                waiter.start(continuation, timeout: 60)
                XCTAssertTrue(waiter.beginLaunch())
                waiter.didLaunch(47)
                waiter.cancel()
                waiter.cancel()
                XCTAssertFalse(waiter.beginLaunch())
                waiter.complete(result())
            }
            XCTFail("原生停止确认不能把取消改为成功")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(terminations.values, [47])
    }

    private func result(code: Int = 0) -> NivoScheduledProcessResult {
        NivoScheduledProcessResult(stdout: "saved output", stderr: "", exitCode: code,
            stdoutBytes: 12, truncated: false, captureError: nil)
    }

    /// 只替换原生kill动作的外部副作用，计时和continuation状态仍使用生产实现。
    private final class Terminations: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [Int32] = []
        var values: [Int32] { lock.withLock { recorded } }
        func append(_ value: Int32) { lock.withLock { recorded.append(value) } }
    }
}
