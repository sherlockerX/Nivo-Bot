import XCTest
@testable import Minis

/// 注入存储失败验证生产提交协调器，真实Apple存储由应用套件另行验收。
@MainActor
final class NivoProviderImportCommitTests: XCTestCase {
    func testCancellationAfterSyncRestoresAllResourcesBeforeClearingJournal() async {
        var queue = "prior"
        var configuration = "prior"
        var credential = "prior"
        var isPending = true
        let operation = Task {
            try await NivoProviderImportCommit.run(writeCredentials: { credential = "replacement" }, persist: {
                configuration = "replacement"
            }, synchronize: {
                queue = "replacement"
                withUnsafeCurrentTask { $0?.cancel() }
            }, finish: { isPending = false }, isPending: { isPending }, rollback: {
                queue = "prior"
                configuration = "prior"
                credential = "prior"
            })
        }
        do { try await operation.value; XCTFail("取消不能报告已提交") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(queue, "prior")
        XCTAssertEqual(configuration, "prior")
        XCTAssertEqual(credential, "prior")
        XCTAssertFalse(isPending)
    }

    func testSyncFailureRollsBackBeforeRemovingRecoveryJournal() async {
        var events: [String] = []
        do {
            try await NivoProviderImportCommit.run(writeCredentials: { events.append("credentials") },
                persist: { events.append("configuration") }, synchronize: {
                    events.append("sync")
                    throw CocoaError(.fileWriteUnknown)
                }, finish: { events.append("finish") }, isPending: { true }, rollback: { events.append("rollback") })
            XCTFail("同步未确认不能报告成功")
        } catch { XCTAssertEqual((error as? CocoaError)?.code, .fileWriteUnknown) }
        XCTAssertEqual(events, ["credentials", "configuration", "sync", "rollback", "finish"])
    }

    func testSuccessConfirmsSyncBeforeCommitMarker() async throws {
        var events: [String] = []
        try await NivoProviderImportCommit.run(writeCredentials: { events.append("credentials") },
            persist: { events.append("configuration") }, synchronize: { events.append("sync") },
            finish: { events.append("finish") }, isPending: { true }, rollback: { XCTFail() })
        XCTAssertEqual(events, ["credentials", "configuration", "sync", "finish"])
    }

    func testMissingRecoveryJournalRefusesEverySideEffect() async {
        do {
            try await NivoProviderImportCommit.run(writeCredentials: { XCTFail() }, persist: { XCTFail() },
                finish: { XCTFail() }, isPending: { false }, rollback: { XCTFail() })
            XCTFail("没有回滚日志不能开始导入")
        } catch { XCTAssertEqual((error as? CocoaError)?.code, .fileReadCorruptFile) }
    }

    func testCancellationAfterPersistenceRollsBackBeforeReleasingJournal() async {
        var isPending = true
        var didRollback = false
        let operation = Task {
            try await NivoProviderImportCommit.run(writeCredentials: {}, persist: {
                withUnsafeCurrentTask { $0?.cancel() }
            }, synchronize: { XCTFail("已取消的配置不再进入发送队列") },
                finish: { isPending = false }, isPending: { isPending }, rollback: { didRollback = true })
        }
        do {
            try await operation.value
            XCTFail("提交标记前取消必须回滚")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(didRollback)
        XCTAssertFalse(isPending)
    }

    func testPartialCredentialFailureRollsBackBeforeFinishingJournal() async {
        var events: [String] = []
        do {
            try await NivoProviderImportCommit.run(writeCredentials: {
                events.append("partial-credentials")
                throw CocoaError(.fileWriteUnknown)
            }, persist: { events.append("configuration") }, finish: { events.append("finish") },
                isPending: { true }, rollback: { events.append("rollback") })
            XCTFail("凭证失败不能报告导入成功")
        } catch {}
        XCTAssertEqual(events, ["partial-credentials", "rollback", "finish"])
    }

    func testConfigurationFailureRestoresCredentialAndOriginalConfiguration() async {
        var credential = "old"
        var configuration = "old"
        var isPending = true
        do {
            try await NivoProviderImportCommit.run(writeCredentials: { credential = "new" }, persist: {
                configuration = "partially-written"
                throw CocoaError(.fileWriteUnknown)
            }, finish: { isPending = false }, isPending: { isPending }, rollback: {
                credential = "old"
                configuration = "old"
            })
            XCTFail("配置没有确认不能报告成功")
        } catch {}
        XCTAssertEqual(credential, "old")
        XCTAssertEqual(configuration, "old")
        XCTAssertFalse(isPending)
    }

    func testRollbackFailureKeepsRecoveryJournal() async {
        var isPending = true
        do {
            try await NivoProviderImportCommit.run(writeCredentials: {}, persist: {
                throw CocoaError(.fileWriteUnknown)
            }, finish: { isPending = false }, isPending: { isPending }, rollback: {
                throw CocoaError(.fileReadNoPermission)
            })
            XCTFail("回滚失败不能完成日志")
        } catch { XCTAssertEqual((error as? CocoaError)?.code, .fileReadNoPermission) }
        XCTAssertTrue(isPending)
    }

    func testFailedMarkerRemovalRestoresBeforeRetryingFinish() async {
        var isPending = true
        var finishes = 0
        var didRollback = false
        do {
            try await NivoProviderImportCommit.run(writeCredentials: {}, persist: {}, finish: {
                finishes += 1
                if finishes == 1 { throw CocoaError(.fileWriteNoPermission) }
                isPending = false
            }, isPending: { isPending }, rollback: { didRollback = true })
            XCTFail("提交标记未确认不能报告成功")
        } catch {}
        XCTAssertTrue(didRollback)
        XCTAssertFalse(isPending)
    }

    func testCommittedImportIsNotRepeatedWhenOnlySnapshotCleanupFails() async throws {
        var isPending = true
        var writes = 0
        try await NivoProviderImportCommit.run(writeCredentials: { writes += 1 }, persist: {}, finish: {
            isPending = false
            throw CocoaError(.fileWriteNoPermission)
        }, isPending: { isPending }, rollback: { XCTFail("已提交后不能再回滚或诱导重复导入") })
        XCTAssertEqual(writes, 1)
    }

    func testSuccessOnlyFinishesAfterConfigurationConfirmation() async throws {
        var events: [String] = []
        try await NivoProviderImportCommit.run(writeCredentials: { events.append("credentials") },
            persist: { events.append("configuration") }, finish: { events.append("finish") },
            isPending: { true }, rollback: { events.append("rollback") })
        XCTAssertEqual(events, ["credentials", "configuration", "finish"])
    }
}
