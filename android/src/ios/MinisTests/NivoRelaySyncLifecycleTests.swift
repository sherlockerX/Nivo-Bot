import XCTest
@testable import Minis

/// 验证同步占位的身份边界，不替代真实URLSession和Apple应用验收。
final class NivoRelaySyncLifecycleTests: XCTestCase {
    private func identity(account: String = "account-a", credential: String = "fixture-key",
                          endpoint: String = "https://example.invalid", generation: UInt64 = 0)
        -> NivoRelaySyncLifecycle.Identity {
        .init(account: account, credential: credential, endpoint: endpoint, accountGeneration: generation)
    }

    func testInvalidationRejectsLateReplyButKeepsInFlightBoundary() throws {
        var lifecycle = NivoRelaySyncLifecycle()
        let lease = try XCTUnwrap(lifecycle.begin(identity()))
        lifecycle.invalidate()
        XCTAssertFalse(lifecycle.accepts(lease, identity: identity()))
        XCTAssertTrue(lifecycle.isBusy)
        XCTAssertNil(lifecycle.begin(identity()))
        XCTAssertTrue(lifecycle.end(lease))
        XCTAssertFalse(lifecycle.isBusy)
    }

    func testSameAccountNewCredentialEndpointAndGenerationAreRejected() throws {
        var lifecycle = NivoRelaySyncLifecycle()
        let lease = try XCTUnwrap(lifecycle.begin(identity()))
        XCTAssertTrue(lifecycle.accepts(lease, identity: identity()))
        XCTAssertFalse(lifecycle.accepts(lease, identity: identity(account: "account-b")))
        XCTAssertFalse(lifecycle.accepts(lease, identity: identity(credential: "replacement-key")))
        XCTAssertFalse(lifecycle.accepts(lease, identity: identity(endpoint: "https://other.invalid")))
        XCTAssertFalse(lifecycle.accepts(lease, identity: identity(generation: 1)))
    }

    func testRepeatedCompletionCannotReleaseNewOperation() throws {
        var lifecycle = NivoRelaySyncLifecycle()
        let old = try XCTUnwrap(lifecycle.begin(identity()))
        XCTAssertTrue(lifecycle.end(old))
        let current = try XCTUnwrap(lifecycle.begin(identity()))
        XCTAssertFalse(lifecycle.end(old))
        XCTAssertTrue(lifecycle.accepts(current, identity: identity()))
        XCTAssertTrue(lifecycle.isBusy)
    }

    func testDelayedIntentCannotCrossDisableAndReenable() {
        var lifecycle = NivoRelaySyncLifecycle()
        let intent = lifecycle.intent(for: identity())
        lifecycle.invalidate()
        lifecycle.invalidate()
        XCTAssertFalse(lifecycle.accepts(intent, identity: identity()))
    }

    func testMissingIdentityDoesNotAcquireLease() {
        var lifecycle = NivoRelaySyncLifecycle()
        XCTAssertNil(lifecycle.begin(identity(account: "")))
        XCTAssertNil(lifecycle.begin(identity(credential: "")))
        XCTAssertFalse(lifecycle.isBusy)
    }
}
