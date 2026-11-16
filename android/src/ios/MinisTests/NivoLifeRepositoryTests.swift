import XCTest
@testable import Minis

/// 真实临时目录验证落盘、幂等、并发版本和账号代次，不接触用户正式档案。
@MainActor
final class NivoLifeRepositoryTests: XCTestCase {
    func testInvalidTransactionNeverReplacesLastReadableArchive() async throws {
        let root = try folder()
        let repository = NivoLifeRepository(directory: root)
        let scope = try await repository.open(ownerKey: "local", clock: clock())
        _ = try await repository.saveTask(NivoTodoTask(ownerKey: "local", title: "Read"),
            operationID: "create", scope: scope, now: 1, today: 10)
        do {
            let _: Bool = try await repository.transaction(operationID: "invalid", request: "invalid", scope: scope) { @Sendable state in
                state.tasks[0].title = ""
                return true
            }
            XCTFail("事务产生不能重新加载的档案时必须拒绝提交")
        } catch { XCTAssertEqual(error as? NivoLifeError, .corruptStore) }
        let reloaded = NivoLifeRepository(directory: root)
        let reopened = try await reloaded.open(ownerKey: "local", clock: clock())
        let snapshot = try await reloaded.snapshot(scope: reopened, clock: clock())
        XCTAssertEqual(snapshot.tasks.first?.title, "Read")
        XCTAssertNil(snapshot.operations["invalid"])
    }

    func testTransactionCannotMoveStateIntoAnotherAccount() async throws {
        let root = try folder()
        let repository = NivoLifeRepository(directory: root)
        let scope = try await repository.open(ownerKey: "first", clock: clock())
        do {
            let _: Bool = try await repository.transaction(operationID: "move", request: "move", scope: scope) { @Sendable state in
                state.ownerKey = "second"
                return true
            }
            XCTFail("事务不能改变账户归属或写入另一账户目录")
        } catch { XCTAssertEqual(error as? NivoLifeError, .accountChanged) }
        let reloaded = NivoLifeRepository(directory: root)
        let other = try await reloaded.open(ownerKey: "second", clock: clock())
        let snapshot = try await reloaded.snapshot(scope: other, clock: clock())
        XCTAssertNil(snapshot.operations["move"])
    }

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nivo-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: url) }
        return url
    }

    private func clock(_ elapsed: Int64 = 0, boot: String = "boot-a") -> NivoFocusClockSample {
        NivoFocusClockSample(wallMs: 1_000_000 + elapsed, elapsedMs: elapsed, bootID: boot)
    }

    func testStaleUpdateDoesNotOverwriteAndExactRetrySurvivesReload() async throws {
        let root = try folder()
        let repository = NivoLifeRepository(directory: root)
        let scope = try await repository.open(ownerKey: "local", clock: clock())
        let draft = NivoTodoTask(ownerKey: "local", title: "Original")
        let original = try await repository.saveTask(draft, operationID: "create", scope: scope, now: 1, today: 10)
        var edit = original
        edit.title = "New"
        _ = try await repository.saveTask(edit, operationID: "edit", scope: scope, now: 2, today: 10)
        do {
            _ = try await repository.saveTask(original, operationID: "stale", scope: scope, now: 3, today: 10)
            XCTFail("旧版本必须被拒绝")
        } catch {
            XCTAssertEqual(error as? NivoLifeError, .staleRevision(expected: 1, actual: 2))
        }
        let reopened = NivoLifeRepository(directory: root)
        let newScope = try await reopened.open(ownerKey: "local", clock: clock())
        let replay = try await reopened.saveTask(draft, operationID: "create", scope: newScope, now: 100, today: 11)
        XCTAssertEqual(replay, original)
        let snapshot = try await reopened.snapshot(scope: newScope, clock: clock())
        XCTAssertEqual(snapshot.tasks.count, 1)
        XCTAssertEqual(snapshot.tasks.first?.title, "New")
    }

    func testSameOperationCannotBecomeAnotherCommand() async throws {
        let repository = NivoLifeRepository(directory: try folder())
        let scope = try await repository.open(ownerKey: "local", clock: clock())
        var draft = NivoTodoTask(ownerKey: "local", title: "First")
        _ = try await repository.saveTask(draft, operationID: "same", scope: scope, now: 1, today: 10)
        draft.title = "Second"
        do {
            _ = try await repository.saveTask(draft, operationID: "same", scope: scope, now: 2, today: 10)
            XCTFail("修改同一操作的内容必须失败")
        } catch { XCTAssertEqual(error as? NivoLifeError, .operationConflict) }
    }

    func testCategoryDeletionCleansReferencesAndPreservesCompletionSnapshot() async throws {
        let repository = NivoLifeRepository(directory: try folder())
        let scope = try await repository.open(ownerKey: "local", clock: clock())
        let task = NivoTodoTask(ownerKey: "local", title: "Report", status: .done, groupName: "Work", tags: ["Study"])
        _ = try await repository.saveTask(task, operationID: "task", scope: scope, now: 1, today: 10)
        let before = try await repository.snapshot(scope: scope, clock: clock())
        let group = try XCTUnwrap(before.categories.first { $0.kind == .group })
        let tag = try XCTUnwrap(before.categories.first { $0.kind == .tag })
        _ = try await repository.deleteCategory(kind: .group, name: "Work", expectedCreatedAt: group.createdAt,
                                                 operationID: "group", scope: scope, now: 2)
        _ = try await repository.deleteCategory(kind: .tag, name: "Study", expectedCreatedAt: tag.createdAt,
                                                 operationID: "tag", scope: scope, now: 3)
        let snapshot = try await repository.snapshot(scope: scope, clock: clock())
        XCTAssertTrue(snapshot.categories.isEmpty)
        XCTAssertEqual(snapshot.tasks.first?.groupName, "")
        XCTAssertEqual(snapshot.tasks.first?.tags, [])
        XCTAssertEqual(snapshot.tasks.first?.completionTags, ["Study"])
        XCTAssertEqual(snapshot.tasks.first?.revision, 3)
    }

    func testOldAccountScopeIsRejectedEvenAfterReturningToSameAccount() async throws {
        let repository = NivoLifeRepository(directory: try folder())
        let first = try await repository.open(ownerKey: "first", clock: clock())
        _ = try await repository.open(ownerKey: "second", clock: clock())
        _ = try await repository.open(ownerKey: "first", clock: clock())
        do {
            _ = try await repository.saveTask(NivoTodoTask(ownerKey: "first", title: "Stale"),
                                               operationID: "old", scope: first, now: 1, today: 10)
            XCTFail("旧账号代次不能复活")
        } catch { XCTAssertEqual(error as? NivoLifeError, .accountChanged) }
    }

    func testFailedDiskWriteDoesNotPublishTaskOrOperation() async throws {
        let repository = NivoLifeRepository(directory: try folder(), writer: { _, _ in
            throw CocoaError(.fileWriteOutOfSpace)
        })
        let scope = try await repository.open(ownerKey: "local", clock: clock())
        do {
            _ = try await repository.saveTask(NivoTodoTask(ownerKey: "local", title: "Unwritten"),
                                               operationID: "failed", scope: scope, now: 1, today: 10)
            XCTFail("磁盘失败不能返回成功")
        } catch { XCTAssertTrue(error is CocoaError) }
        let snapshot = try await repository.snapshot(scope: scope, clock: clock())
        XCTAssertTrue(snapshot.tasks.isEmpty)
        XCTAssertTrue(snapshot.operations.isEmpty)
    }

    func testFocusIsActiveAndDoesNotFinishOnEarlyPause() async throws {
        let repository = NivoLifeRepository(directory: try folder())
        let scope = try await repository.open(ownerKey: "local", clock: clock())
        let started = try await repository.startFocus(title: "Read", mode: .pomodoro, minutes: 3,
                                                       operationID: "start", scope: scope, clock: clock())
        let snapshot = try await repository.snapshot(scope: scope, clock: clock(1_000))
        XCTAssertEqual(snapshot.focusSessions.filter(\.isActive).count, 1)
        let paused = try await repository.controlFocus(action: "pause", id: started.id, expectedRevision: 1,
                                                        operationID: "pause", scope: scope, clock: clock(1_000))
        XCTAssertEqual(paused.status, .paused)
        XCTAssertEqual(paused.elapsedMs, 1_000)
        let replay = try await repository.startFocus(title: "Read", mode: .pomodoro, minutes: 3,
                                                      operationID: "start", scope: scope, clock: clock(90_000))
        XCTAssertEqual(replay, started)
        let current = try await repository.snapshot(scope: scope, clock: clock(90_000))
        XCTAssertEqual(current.focusSessions.first?.status, .paused)
        XCTAssertEqual(current.focusSpans.count, 1)
    }

    func testVisibleCountdownSettlesOnceAndSurvivesRestart() async throws {
        let root = try folder()
        let repository = NivoLifeRepository(directory: root)
        let scope = try await repository.open(ownerKey: "local", clock: clock())
        let started = try await repository.startFocus(title: "Read", mode: .pomodoro, minutes: 3,
            operationID: "start", scope: scope, clock: clock())
        let before = try await repository.snapshot(scope: scope, clock: clock(30_000))
        XCTAssertFalse(NivoFocusPresentationRules.needsReconciliation(started, clock: clock(30_000)))
        XCTAssertTrue(NivoFocusPresentationRules.needsReconciliation(started, clock: clock(180_000)))
        let finished = try await repository.snapshot(scope: scope, clock: clock(180_000))
        XCTAssertEqual(finished.focusSessions.first?.status, .finished)
        XCTAssertEqual(finished.focusSessions.first?.elapsedMs, 180_000)
        XCTAssertEqual(finished.focusSessions.first?.endedAt, clock(180_000).wallMs)
        XCTAssertEqual(finished.storeRevision, (before.storeRevision ?? 0) + 1)
        XCTAssertEqual(finished.focusSpans.count, 1)
        let repeated = try await repository.snapshot(scope: scope, clock: clock(181_000))
        XCTAssertEqual(repeated, finished)
        let reloaded = NivoLifeRepository(directory: root)
        let reopened = try await reloaded.open(ownerKey: "local", clock: clock(190_000))
        let restored = try await reloaded.snapshot(scope: reopened, clock: clock(190_000))
        XCTAssertEqual(restored, finished)
    }

    func testRecreatedCategoryRejectsOldDeletionEvenWhenClockDoesNotMove() async throws {
        let repository = NivoLifeRepository(directory: try folder())
        let scope = try await repository.open(ownerKey: "local", clock: clock())
        let first = try await repository.createCategory(kind: .group, name: "Study", operationID: "first", scope: scope, now: 10)
        _ = try await repository.deleteCategory(kind: .group, name: first.name, expectedCreatedAt: first.createdAt,
                                                operationID: "delete-first", scope: scope, now: 10)
        let second = try await repository.createCategory(kind: .group, name: "Study", operationID: "second", scope: scope, now: 10)
        XCTAssertNotEqual(first.createdAt, second.createdAt)
        do {
            _ = try await repository.deleteCategory(kind: .group, name: first.name, expectedCreatedAt: first.createdAt,
                                                    operationID: "stale-delete", scope: scope, now: 10)
            XCTFail("旧删除不能命中同名新分类")
        } catch { XCTAssertEqual(error as? NivoLifeError, .staleRevision(expected: first.createdAt, actual: second.createdAt)) }
    }

    func testCategoryRemovalAndDeletionSurviveClockRollbackAndReload() async throws {
        let root = try folder()
        let repository = NivoLifeRepository(directory: root)
        let scope = try await repository.open(ownerKey: "local", clock: clock())
        let task = try await repository.saveTask(NivoTodoTask(ownerKey: "local", title: "Read", groupName: "Study"),
            operationID: "create", scope: scope, now: 100, today: 10)
        let initial = try await repository.snapshot(scope: scope, clock: clock())
        let group = try XCTUnwrap(initial.categories.first)
        _ = try await repository.deleteCategory(kind: .group, name: group.name, expectedCreatedAt: group.createdAt,
            operationID: "delete-group", scope: scope, now: 50)
        let deleted = try await repository.deleteTask(id: task.id, expectedRevision: 2,
            operationID: "delete-task", scope: scope, now: 40)
        XCTAssertEqual(deleted.updatedAt, 100)
        XCTAssertEqual(deleted.deletedAt, 40)
        let reloaded = NivoLifeRepository(directory: root)
        let reloadedScope = try await reloaded.open(ownerKey: "local", clock: clock())
        let snapshot = try await reloaded.snapshot(scope: reloadedScope, clock: clock())
        XCTAssertEqual(snapshot.tasks.first, deleted)
        XCTAssertTrue(snapshot.categories.isEmpty)
    }

    func testRemovingOneAccountPreservesOtherAccountAndRevokesScope() async throws {
        let root = try folder()
        let repository = NivoLifeRepository(directory: root)
        let first = try await repository.open(ownerKey: "first", clock: clock())
        _ = try await repository.saveTask(NivoTodoTask(ownerKey: "first", title: "A"), operationID: "a", scope: first, now: 1, today: 10)
        let second = try await repository.open(ownerKey: "second", clock: clock())
        _ = try await repository.saveTask(NivoTodoTask(ownerKey: "second", title: "B"), operationID: "b", scope: second, now: 1, today: 10)
        try await repository.removeAccount(ownerKey: "second")
        do {
            _ = try await repository.snapshot(scope: second, clock: clock())
            XCTFail("删除后旧凭证应失效")
        } catch { XCTAssertEqual(error as? NivoLifeError, .accountChanged) }
        let kept = try await repository.open(ownerKey: "first", clock: clock())
        let snapshot = try await repository.snapshot(scope: kept, clock: clock())
        XCTAssertEqual(snapshot.tasks.map(\.title), ["A"])
        let erased = try await repository.open(ownerKey: "second", clock: clock())
        let empty = try await repository.snapshot(scope: erased, clock: clock())
        XCTAssertTrue(empty.tasks.isEmpty)
    }
}
