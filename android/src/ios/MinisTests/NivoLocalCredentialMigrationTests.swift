import XCTest
@testable import Minis

/// 本机凭据迁移只在目标经过读回且来源未变化后才清理旧同步条目。
final class NivoLocalCredentialMigrationTests: XCTestCase {
    func testCopiesBeforeDeletingAndRepeatsSafely() throws {
        let store = Fixture()
        try store.migrate()
        XCTAssertEqual(store.local, store.original)
        XCTAssertNil(store.cloud)
        XCTAssertEqual(store.events, ["insert", "delete"])
        try store.migrate()
        XCTAssertEqual(store.events, ["insert", "delete"])
    }

    func testExistingLocalValueWinsOverOldCloudValue() throws {
        let store = Fixture()
        store.local = Data("new-local-value".utf8)
        try store.migrate()
        XCTAssertEqual(store.local, Data("new-local-value".utf8))
        XCTAssertNil(store.cloud)
        XCTAssertEqual(store.events, ["delete"])
    }

    func testWriteFailurePreservesCloudSource() {
        let store = Fixture()
        store.failInsert = true
        XCTAssertThrowsError(try store.migrate())
        XCTAssertEqual(store.cloud, store.original)
        XCTAssertNil(store.local)
        XCTAssertFalse(store.events.contains("delete"))
    }

    func testReadbackFailurePreservesCloudSource() {
        let store = Fixture()
        store.corruptInsert = true
        XCTAssertThrowsError(try store.migrate())
        XCTAssertEqual(store.cloud, store.original)
        XCTAssertFalse(store.events.contains("delete"))
    }

    func testChangedCloudSnapshotIsNotDeleted() {
        let store = Fixture()
        store.changeCloudAfterInsert = true
        XCTAssertThrowsError(try store.migrate())
        XCTAssertEqual(store.cloud, Data("concurrent-cloud-value".utf8))
        XCTAssertFalse(store.events.contains("delete"))
    }

    func testConcurrentLocalInsertIsPreservedAndMigrationCanRetry() {
        let store = Fixture()
        store.concurrentInsert = true
        XCTAssertThrowsError(try store.migrate())
        XCTAssertEqual(store.local, Data("concurrent-local-value".utf8))
        XCTAssertEqual(store.cloud, store.original)
    }

    func testFailedCloudDeleteRetainsVerifiedLocalCopyAndRetrySkipsInsert() throws {
        let store = Fixture()
        store.failDelete = true
        XCTAssertThrowsError(try store.migrate())
        XCTAssertEqual(store.local, store.original)
        XCTAssertEqual(store.cloud, store.original)
        store.failDelete = false
        try store.migrate()
        XCTAssertNil(store.cloud)
        XCTAssertEqual(store.local, store.original)
        XCTAssertEqual(store.events, ["insert", "delete"])
    }

    func testUnreadableLocalValueIsNotTreatedAsMissing() {
        let store = Fixture()
        store.failLocalRead = true
        XCTAssertThrowsError(try store.migrate())
        XCTAssertEqual(store.cloud, store.original)
        XCTAssertTrue(store.events.isEmpty)
    }

    func testDeleteWithoutRemovalCannotReportSuccess() {
        let store = Fixture()
        store.ignoreDelete = true
        XCTAssertThrowsError(try store.migrate())
        XCTAssertEqual(store.local, store.original)
        XCTAssertEqual(store.cloud, store.original)
    }

    func testScopeExcludesIdentityMCPAndRecoveryServices() {
        XCTAssertTrue(NivoLocalCredentialMigration.includes(service: "io.github.nanomuse.app.provider.fixture", account: "api-key"))
        XCTAssertTrue(NivoLocalCredentialMigration.includes(service: "io.github.nanomuse.app.provider.fixture", account: "oauth-token"))
        XCTAssertTrue(NivoLocalCredentialMigration.includes(service: "io.github.nanomuse.app.envvar", account: "CUSTOM_KEY"))
        for service in ["io.github.nanomuse.app.device", "io.github.nanomuse.app.mcp-oauth", "io.github.nanomuse.app.provider-key-rotation"] {
            XCTAssertFalse(NivoLocalCredentialMigration.includes(service: service, account: "api-key"))
        }
        XCTAssertFalse(NivoLocalCredentialMigration.includes(service: "other.app.provider.fixture", account: "api-key"))
    }

    private final class Fixture {
        let original = Data("fixture-value".utf8)
        var cloud: Data? = Data("fixture-value".utf8)
        var local: Data?
        var events: [String] = []
        var failInsert = false
        var corruptInsert = false
        var changeCloudAfterInsert = false
        var concurrentInsert = false
        var failDelete = false
        var failLocalRead = false
        var ignoreDelete = false

        /// 测试使用同一生产迁移顺序，仅替换系统存储接口。
        func migrate() throws {
            try NivoLocalCredentialMigration.migrate(
                readCloud: { self.cloud }, readLocal: {
                    if self.failLocalRead { throw CocoaError(.fileReadNoPermission) }
                    return self.local
                },
                insertLocal: { value in
                    if self.failInsert { throw CocoaError(.fileWriteUnknown) }
                    if self.concurrentInsert {
                        self.local = Data("concurrent-local-value".utf8)
                        throw CocoaError(.fileWriteFileExists)
                    }
                    self.events.append("insert")
                    self.local = self.corruptInsert ? Data("broken".utf8) : value
                    if self.changeCloudAfterInsert { self.cloud = Data("concurrent-cloud-value".utf8) }
                }, removeCloud: { expected in
                    if self.failDelete { throw CocoaError(.fileWriteUnknown) }
                    if self.ignoreDelete { return }
                    guard self.cloud == expected else { throw CocoaError(.fileReadCorruptFile) }
                    self.events.append("delete")
                    self.cloud = nil
                })
        }
    }
}
