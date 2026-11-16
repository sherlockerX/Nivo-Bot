import XCTest
@testable import Minis

/// 验证保存之前的真实操作屏障，闭包仅记录是否发生了凭证副作用。
@MainActor
final class NivoOAuthLifecycleTests: XCTestCase {
    private let scope = NivoOAuthScope(ownerKey: "fixture-owner", accountGeneration: 1, providerGeneration: 1)

    func testNewLoginRejectsEarlierRefreshWithoutTouchingItsCredential() async throws {
        let lifecycle = NivoOAuthLifecycle()
        let refresh = try lifecycle.begin(instanceID: "fixture", scope: scope)
        let login = try lifecycle.begin(instanceID: "fixture", scope: scope, replacing: true)
        XCTAssertNotEqual(refresh.generation, login.generation)
        XCTAssertThrowsError(try lifecycle.validate(refresh, scope: scope))
        XCTAssertNoThrow(try lifecycle.validate(login, scope: scope))
    }

    func testLogoutRejectsLateLoginAndAncillaryMetadata() async throws {
        let lifecycle = NivoOAuthLifecycle()
        let login = try lifecycle.begin(instanceID: "fixture", scope: scope, replacing: true)
        lifecycle.invalidate(instanceID: "fixture")
        XCTAssertThrowsError(try lifecycle.validate(login, scope: scope))
    }

    func testSameAccountRestoreRejectsOldOperation() async throws {
        let lifecycle = NivoOAuthLifecycle()
        let login = try lifecycle.begin(instanceID: "fixture", scope: scope)
        let restored = NivoOAuthScope(ownerKey: scope.ownerKey, accountGeneration: 1, providerGeneration: 2)
        XCTAssertThrowsError(try lifecycle.validate(login, scope: restored))
        XCTAssertNotEqual(try lifecycle.begin(instanceID: "fixture", scope: restored).generation, login.generation)
    }

    func testAccountRoundTripDoesNotReviveOldOperation() async throws {
        let lifecycle = NivoOAuthLifecycle()
        let login = try lifecycle.begin(instanceID: "fixture", scope: scope)
        let returned = NivoOAuthScope(ownerKey: scope.ownerKey, accountGeneration: 3, providerGeneration: 1)
        XCTAssertThrowsError(try lifecycle.validate(login, scope: returned))
    }

    func testDeletingOneInstancePreservesOtherLogin() async throws {
        let lifecycle = NivoOAuthLifecycle()
        let removed = try lifecycle.begin(instanceID: "removed", scope: scope)
        let retained = try lifecycle.begin(instanceID: "retained", scope: scope)
        lifecycle.invalidate(instanceID: "removed")
        XCTAssertThrowsError(try lifecycle.validate(removed, scope: scope))
        XCTAssertNoThrow(try lifecycle.validate(retained, scope: scope))
    }

    func testParallelRefreshesShareGenerationUntilNewLogin() async throws {
        let lifecycle = NivoOAuthLifecycle()
        let first = try lifecycle.begin(instanceID: "fixture", scope: scope)
        let second = try lifecycle.begin(instanceID: "fixture", scope: scope)
        XCTAssertEqual(first, second)
    }

    func testOldLoginCleanupCannotRemoveNewCancellation() async throws {
        let lifecycle = NivoOAuthLifecycle()
        let old = try lifecycle.begin(instanceID: "fixture", scope: scope, replacing: true)
        var oldStops = 0
        var newStops = 0
        try lifecycle.registerCancellation(old) { oldStops += 1 }
        let current = try lifecycle.begin(instanceID: "fixture", scope: scope, replacing: true)
        try lifecycle.registerCancellation(current) { newStops += 1 }
        lifecycle.finish(old)
        lifecycle.invalidate(instanceID: "fixture")
        lifecycle.invalidate(instanceID: "fixture")
        XCTAssertEqual(oldStops, 1)
        XCTAssertEqual(newStops, 1)
    }

    func testAccountChangeStopsAllCallbackWaitersExactlyOnce() async throws {
        let lifecycle = NivoOAuthLifecycle()
        var stops = 0
        for identifier in ["first", "second"] {
            let operation = try lifecycle.begin(instanceID: identifier, scope: scope)
            try lifecycle.registerCancellation(operation) { stops += 1 }
        }
        lifecycle.invalidateAll()
        lifecycle.invalidateAll()
        XCTAssertEqual(stops, 2)
    }

    func testDelayedCancellationOnlyCancelsItsOwnLogin() async throws {
        let lifecycle = NivoOAuthLifecycle()
        let old = try lifecycle.begin(instanceID: "fixture", scope: scope)
        let current = try lifecycle.begin(instanceID: "fixture", scope: scope, replacing: true)
        lifecycle.invalidate(old)
        XCTAssertNoThrow(try lifecycle.validate(current, scope: scope))
    }

    func testRefreshWaitsUntilReplacementLoginHasFinished() async throws {
        let lifecycle = NivoOAuthLifecycle()
        let login = try lifecycle.begin(instanceID: "fixture", scope: scope, replacing: true)
        XCTAssertThrowsError(try lifecycle.begin(instanceID: "fixture", scope: scope))
        lifecycle.finish(login)
        XCTAssertNoThrow(try lifecycle.begin(instanceID: "fixture", scope: scope))
    }
}
