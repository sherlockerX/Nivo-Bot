import XCTest
@testable import Minis

/// 凭证持久化故障测试，存储闭包注入失败，不连接真实账户或网络。
final class NivoOAuthPersistenceTests: XCTestCase {
    func testRefreshRejectsCredentialDeletedDuringNetworkWait() throws {
        XCTAssertThrowsError(try NivoOAuthPersistence.requireUnchanged(accessToken: "old", refreshToken: nil,
            currentAccessToken: nil, currentRefreshToken: nil))
    }

    func testRefreshRejectsNewAccessTokenEvenWhenRefreshTokenUnchanged() throws {
        XCTAssertThrowsError(try NivoOAuthPersistence.requireUnchanged(accessToken: "old", refreshToken: "same",
            currentAccessToken: "new", currentRefreshToken: "same"))
    }

    func testRefreshRejectsExternallyRotatedRefreshToken() throws {
        XCTAssertThrowsError(try NivoOAuthPersistence.requireUnchanged(accessToken: "same", refreshToken: "old",
            currentAccessToken: "same", currentRefreshToken: "new"))
    }

    func testRefreshMayCommitWhenObservedCredentialIsStillCurrent() throws {
        XCTAssertNoThrow(try NivoOAuthPersistence.requireUnchanged(accessToken: "current", refreshToken: "current",
            currentAccessToken: "current", currentRefreshToken: "current"))
    }

    func testFailedUpdatePreservesPreviouslyStoredCredential() throws {
        var saved = Data("fixture-original".utf8)
        XCTAssertThrowsError(try NivoOAuthPersistence.save(Data("fixture-new".utf8), read: { saved },
            update: { _ in throw NivoOAuthPersistenceError.storage(operation: "update", status: -1) },
            insert: { saved = $0 }))
        XCTAssertEqual(saved, Data("fixture-original".utf8))
    }

    func testUnreadableCredentialDoesNotFallThroughToInsert() throws {
        var writes = 0
        XCTAssertThrowsError(try NivoOAuthPersistence.save(Data("fixture-new".utf8),
            read: { throw NivoOAuthPersistenceError.storage(operation: "read", status: -1) },
            update: { _ in writes += 1 }, insert: { _ in writes += 1 }))
        XCTAssertEqual(writes, 0)
    }

    func testNewCredentialIsReadBackBeforeSuccess() throws {
        var saved: Data?
        var reads = 0
        try NivoOAuthPersistence.save(Data("fixture-new".utf8), read: { reads += 1; return saved },
            update: { _ in XCTFail("缺少记录时不能更新") }, insert: { saved = $0 })
        XCTAssertEqual(saved, Data("fixture-new".utf8))
        XCTAssertEqual(reads, 2)
    }

    func testUnconfirmedWriteThrowsWithoutReportingSuccess() throws {
        XCTAssertThrowsError(try NivoOAuthPersistence.save(Data("fixture-new".utf8), read: { nil },
            update: { _ in }, insert: { _ in })) { error in
            XCTAssertEqual(error as? NivoOAuthPersistenceError, .verificationFailed)
        }
    }

    func testDuplicateInsertDoesNotOverwriteConcurrentCredential() throws {
        var saved: Data?
        XCTAssertThrowsError(try NivoOAuthPersistence.save(Data("fixture-new".utf8), read: { saved },
            update: { _ in XCTFail("并发新增失败不得转为盲目覆盖") }, insert: { _ in
                saved = Data("fixture-concurrent".utf8)
                throw NivoOAuthPersistenceError.storage(operation: "insert", status: -1)
            }))
        XCTAssertEqual(saved, Data("fixture-concurrent".utf8))
    }

    func testOversizedOrEmptyValueDoesNotTouchStorage() throws {
        for data in [Data(), Data(repeating: 1, count: 1_048_577)] {
            XCTAssertThrowsError(try NivoOAuthPersistence.save(data,
                read: { XCTFail("无效输入不得读取存储"); return nil },
                update: { _ in XCTFail() }, insert: { _ in XCTFail() }))
        }
    }

    func testMigrationDoesNotReplaceDifferentExistingCredential() throws {
        var writes = 0
        XCTAssertThrowsError(try NivoOAuthPersistence.copyMissing(Data("fixture-legacy".utf8),
            read: { Data("fixture-existing".utf8) }, write: { _ in writes += 1 }))
        XCTAssertEqual(writes, 0)
    }

    func testRepeatedMigrationAcceptsConfirmedValueWithoutWriting() throws {
        let legacy = Data("fixture-legacy".utf8)
        try NivoOAuthPersistence.copyMissing(legacy, read: { legacy }, write: { _ in XCTFail() })
    }
}
