import XCTest
#if canImport(NivoOAuthSupport)
@testable import NivoOAuthSupport
#else
@testable import Minis
#endif

/// 用显式屏障还原授权网络不响应取消的时序，不接触真实账户或凭证。
@MainActor
final class NivoOAuthFlightTests: XCTestCase {
    func testCancelledCallerDoesNotReceiveLateSuccessfulRefresh() async {
        let flights = OAuthRefreshSingleFlight<String>()
        let network = OAuthNetworkBarrier()
        let request = Task {
            try await flights.run(instanceId: "fixture") { await network.wait() }
        }
        await network.waitUntilStarted()
        request.cancel()
        network.finish("late-response")
        do {
            _ = try await request.value
            XCTFail("已经取消的调用不能继续返回有效令牌")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertFalse(flights.hasInFlight("fixture"))
    }

    func testCancelledRequestNeverStartsNetwork() async {
        let flights = OAuthRefreshSingleFlight<String>()
        let entered = OAuthNetworkBarrier()
        var networkCalls = 0
        let request = Task {
            _ = await entered.wait()
            return try await flights.run(instanceId: "fixture") {
                networkCalls += 1
                return "unexpected"
            }
        }
        await entered.waitUntilStarted()
        request.cancel()
        entered.finish("continue")
        do {
            _ = try await request.value
            XCTFail("已取消的入口不能发起新请求")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(networkCalls, 0)
    }

    func testNewLoginGenerationDoesNotJoinOldRefresh() async throws {
        let flights = OAuthRefreshSingleFlight<String>()
        let oldNetwork = OAuthNetworkBarrier()
        let old = Task {
            try await flights.run(instanceId: "fixture", generation: UUID()) { await oldNetwork.wait() }
        }
        await oldNetwork.waitUntilStarted()
        let fresh = try await flights.run(instanceId: "fixture", generation: UUID()) { "new-login" }
        XCTAssertEqual(fresh, "new-login")
        oldNetwork.finish("old-login")
        let oldResult = try await old.value
        XCTAssertEqual(oldResult, "old-login")
    }

    func testOldCleanupCannotRemoveReplacementFlight() async throws {
        let flights = OAuthRefreshSingleFlight<String>()
        let oldNetwork = OAuthNetworkBarrier()
        let newNetwork = OAuthNetworkBarrier()
        let old = Task { try await flights.run(instanceId: "fixture") { await oldNetwork.wait() } }
        await oldNetwork.waitUntilStarted()
        flights.invalidate(instanceId: "fixture")
        let replacement = Task { try await flights.run(instanceId: "fixture") { await newNetwork.wait() } }
        await newNetwork.waitUntilStarted()
        oldNetwork.finish("late-old")
        do {
            _ = try await old.value
            XCTFail("已作废的刷新不能报告成功")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(flights.hasInFlight("fixture"))
        newNetwork.finish("replacement")
        let result = try await replacement.value
        XCTAssertEqual(result, "replacement")
        XCTAssertFalse(flights.hasInFlight("fixture"))
    }

    func testCancelledJoinerDoesNotCancelOtherCaller() async throws {
        let flights = OAuthRefreshSingleFlight<String>()
        let network = OAuthNetworkBarrier()
        var networkCalls = 0
        let original = Task {
            try await flights.run(instanceId: "fixture") {
                networkCalls += 1
                return await network.wait()
            }
        }
        await network.waitUntilStarted()
        var joiner: Task<String, Error>?
        await withCheckedContinuation { (arrived: CheckedContinuation<Void, Never>) in
            joiner = Task {
                arrived.resume()
                return try await flights.run(instanceId: "fixture") {
                    networkCalls += 1
                    return "unexpected-second-network"
                }
            }
        }
        joiner?.cancel()
        network.finish("shared-result")
        let result = try await original.value
        XCTAssertEqual(result, "shared-result")
        do {
            _ = try await joiner?.value
            XCTFail("已取消的等待者不能接受共享结果")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(networkCalls, 1)
    }

    func testFailedNetworkDoesNotPreventNextRefresh() async throws {
        let flights = OAuthRefreshSingleFlight<String>()
        do {
            _ = try await flights.run(instanceId: "fixture") { throw CocoaError(.fileReadUnknown) }
            XCTFail("网络失败应传播")
        } catch { XCTAssertFalse(flights.hasInFlight("fixture")) }
        let result = try await flights.run(instanceId: "fixture") { "retry" }
        XCTAssertEqual(result, "retry")
    }
}

/// 只控制网络返回时间；被测单飞协调器始终为生产实现。
@MainActor
private final class OAuthNetworkBarrier {
    private var response: CheckedContinuation<String, Never>?
    private var started: CheckedContinuation<Void, Never>?

    func wait() async -> String {
        await withCheckedContinuation { continuation in
            response = continuation
            started?.resume()
            started = nil
        }
    }

    func waitUntilStarted() async {
        if response != nil { return }
        await withCheckedContinuation { started = $0 }
    }

    func finish(_ value: String) {
        response?.resume(returning: value)
        response = nil
    }
}
