import XCTest
@testable import Minis

/// 使用同一生产校验入口区分授权撤销与业务错误，不读取用户档案。
final class NivoPersonalRecordsRecoveryTests: XCTestCase {
    func testUnchangedForegroundContextNeedsNoTimeBasedRenewal() throws {
        let (context, authorization) = fixture()
        try context.require(authorization)
        try context.require(authorization)
        XCTAssertThrowsError(try context.require(nil)) { error in
            XCTAssertEqual(error as? NivoPersonalRecordsAccessError, .userTurnRequired)
        }
    }

    func testBackgroundAndHiddenPageHaveSpecificRecoveryErrors() throws {
        let (original, authorization) = fixture()
        var context = original
        context.isForeground = false
        XCTAssertThrowsError(try context.require(authorization)) { error in
            XCTAssertEqual(error as? NivoPersonalRecordsAccessError, .foregroundRequired)
        }
        context.isForeground = true
        context.isVisible = false
        XCTAssertThrowsError(try context.require(authorization)) { error in
            XCTAssertEqual(error as? NivoPersonalRecordsAccessError, .conversationHidden)
        }
    }

    func testReturnToForegroundDoesNotReviveRevokedAuthorization() throws {
        let (original, authorization) = fixture()
        var context = original
        context.visibilityID = UUID()
        context.authorization = nil
        XCTAssertThrowsError(try context.require(authorization)) { error in
            XCTAssertEqual(error as? NivoPersonalRecordsAccessError, .authorizationRevoked)
        }
        XCTAssertTrue(NivoPersonalRecordsAccessError.authorizationRevoked.localizedDescription.contains("new request"))
    }

    func testChangedTurnAccountAndDispatchCannotReuseAuthorization() throws {
        let (original, authorization) = fixture()
        var changed = original
        changed.turnID = UUID()
        XCTAssertThrowsError(try changed.require(authorization)) { error in
            XCTAssertEqual(error as? NivoPersonalRecordsAccessError, .turnChanged)
        }
        changed = original
        changed.ownerKey = "other"
        XCTAssertThrowsError(try changed.require(authorization)) { error in
            XCTAssertEqual(error as? NivoPersonalRecordsAccessError, .accountChanged)
        }
        changed = original
        changed.isDispatch = true
        XCTAssertThrowsError(try changed.require(authorization)) { error in
            XCTAssertEqual(error as? NivoPersonalRecordsAccessError, .userTurnRequired)
        }
    }

    func testFailuresHaveStableCodesAndDoNotExposePrivatePaths() throws {
        let invalid = try object(NivoLifeToolFailure.output(NivoLifeError.invalidField("unexpected_fields")))
        XCTAssertEqual(invalid["success"] as? Bool, false)
        XCTAssertEqual(invalid["error"] as? String, "invalid_field")
        XCTAssertEqual(invalid["field"] as? String, "unexpected_fields")
        let revoked = try object(NivoLifeToolFailure.output(NivoPersonalRecordsAccessError.authorizationRevoked))
        XCTAssertEqual(revoked["error"] as? String, "records_authorization_revoked")
        XCTAssertEqual(revoked["requiresNewUserTurn"] as? Bool, true)
        let disk = NSError(domain: NSCocoaErrorDomain, code: 260, userInfo: [NSFilePathErrorKey: "/private/owner/records.json"])
        let output = NivoLifeToolFailure.output(disk)
        XCTAssertFalse(output.contains("/private/"))
        XCTAssertEqual(try object(output)["error"] as? String, "records_unavailable")
        XCTAssertEqual(try object(NivoLifeToolFailure.output(NivoLifeError.accountChanged))["error"] as? String, "account_changed")
        XCTAssertEqual(try object(NivoLifeToolFailure.output(NivoJigsawExecutionError.permissionDenied))["error"] as? String, "permission_denied")
        XCTAssertEqual(try object(NivoLifeToolFailure.output(NivoJigsawExecutionError.timedOut))["error"] as? String, "query_timeout")
    }

    func testLifeAndCoachConflictOutputRetainsLegacyCodeField() throws {
        let result = try object(NivoLifeToolFailure.output(NivoLifeError.staleRevision(expected: 1, actual: 2)))
        XCTAssertEqual(result["code"] as? String, "stale_revision")
        XCTAssertEqual(result["error"] as? String, result["code"] as? String)
        XCTAssertEqual(result["expectedRevision"] as? Int, 1)
        XCTAssertEqual(result["actualRevision"] as? Int, 2)
        XCTAssertEqual(result["success"] as? Bool, false)
    }

    private func fixture() -> (NivoPersonalRecordsAccessContext, NivoPersonalRecordsAuthorization) {
        let scope = NivoLifeScope(ownerKey: "isolated-owner", generation: 1)
        let user = NivoSavedUserTurn(id: "row", text: "Read my saved records", ownerKey: scope.ownerKey,
            chatSessionID: "chat", createdAt: 1)
        let token = NivoPersonalRecordsAuthorization(hostID: "host", turnID: UUID(), scope: scope,
            user: user, visibilityID: UUID())
        let context = NivoPersonalRecordsAccessContext(hostID: token.hostID, turnID: token.turnID,
            visibilityID: token.visibilityID, authorization: token, scope: scope, ownerKey: scope.ownerKey,
            sessionID: "chat", isForeground: true, isVisible: true, isAccountReady: true,
            isDispatch: false, isSessionOwned: true)
        return (context, token)
    }

    private func object(_ output: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
    }
}
