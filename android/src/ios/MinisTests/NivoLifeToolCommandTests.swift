import XCTest
@testable import Minis

/// 验证实际工具命令的事务与解析边界，不修改用户正式账户或调用真实模型。
@MainActor
final class NivoLifeToolCommandTests: XCTestCase {
    private let identity = NivoLifeToolIdentity(chatID: "chat", messageID: "user", sourceDigest: String(repeating: "a", count: 64))

    private func repository() throws -> NivoLifeRepository {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("life-tool-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: folder) }
        return NivoLifeRepository(directory: folder)
    }

    private func clock(_ elapsed: Int64 = 0) -> NivoFocusClockSample {
        NivoFocusClockSample(wallMs: 1_000_000 + elapsed, elapsedMs: elapsed, bootID: "boot")
    }

    private func task(_ result: NivoTodoToolResult) throws -> NivoTodoTask {
        guard case .task(let value) = result else { throw NivoLifeError.invalidField("test_result") }
        return value
    }

    private func create(_ repository: NivoLifeRepository, scope: NivoLifeScope) async throws -> NivoTodoTask {
        let command = NivoTodoToolCommand(action: "create", identity: identity, patch: NivoTodoToolPatch(title: "Read"))
        return try task(await repository.executeTodoTool(command, operationID: "create", scope: scope, now: 1, today: 10))
    }

    func testPatchRetryAfterLaterEditReturnsOriginalSnapshotWithoutOverwriting() async throws {
        let repository = try repository()
        let scope = try await repository.open(ownerKey: "owner", clock: clock())
        let first = try await create(repository, scope: scope)
        let request = NivoTodoToolCommand(action: "update", identity: identity, targetID: first.id,
            expectedRevision: first.revision, patch: NivoTodoToolPatch(title: "First edit", scheduledDay: 9))
        let edited = try task(await repository.executeTodoTool(request, operationID: "edit", scope: scope, now: 2, today: 10))
        var later = edited
        later.notes = "Written in the task editor"
        let latest = try await repository.saveTask(later, operationID: "manual", scope: scope, now: 3, today: 10)
        let replay = try task(await repository.executeTodoTool(request, operationID: "edit", scope: scope, now: 4, today: 11))
        XCTAssertEqual(replay, edited)
        let snapshot = try await repository.snapshot(scope: scope, clock: clock())
        XCTAssertEqual(snapshot.tasks.first, latest)
    }

    func testStaleToolRevisionIsRejectedAndLeavesTaskUntouched() async throws {
        let repository = try repository()
        let scope = try await repository.open(ownerKey: "owner", clock: clock())
        let first = try await create(repository, scope: scope)
        _ = try await repository.changeTaskStatus(id: first.id, status: .inProgress, expectedRevision: 1,
            operationID: "manual", scope: scope, now: 2, today: 10)
        let request = NivoTodoToolCommand(action: "update", identity: identity, targetID: first.id,
            expectedRevision: 1, patch: NivoTodoToolPatch(title: "Stale edit"))
        do {
            _ = try await repository.executeTodoTool(request, operationID: "stale", scope: scope, now: 3, today: 10)
            XCTFail("旧版本请求必须被拒绝")
        } catch { XCTAssertEqual(error as? NivoLifeError, .staleRevision(expected: 1, actual: 2)) }
        let snapshot = try await repository.snapshot(scope: scope, clock: clock())
        XCTAssertEqual(snapshot.tasks.first?.title, "Read")
        XCTAssertNil(snapshot.operations["stale"])
    }

    func testDeletedTaskRequestCanBeReplayed() async throws {
        let repository = try repository()
        let scope = try await repository.open(ownerKey: "owner", clock: clock())
        let first = try await create(repository, scope: scope)
        let request = NivoTodoToolCommand(action: "delete", identity: identity, targetID: first.id, expectedRevision: first.revision)
        let deleted = try task(await repository.executeTodoTool(request, operationID: "delete", scope: scope, now: 2, today: 10))
        let replay = try task(await repository.executeTodoTool(request, operationID: "delete", scope: scope, now: 100, today: 11))
        XCTAssertEqual(replay, deleted)
        XCTAssertEqual(replay.deletedAt, 2)
    }

    func testCategoryDeleteReplayDoesNotDeleteRecreatedCategory() async throws {
        let repository = try repository()
        let scope = try await repository.open(ownerKey: "owner", clock: clock())
        let first = try await repository.createCategory(kind: .group, name: "Study", operationID: "group", scope: scope, now: 1)
        let request = NivoTodoToolCommand(action: "delete_category", identity: identity,
            categoryKind: .group, categoryName: "Study", expectedCreatedAt: first.createdAt)
        _ = try await repository.executeTodoTool(request, operationID: "delete", scope: scope, now: 2, today: 10)
        let recreated = try await repository.createCategory(kind: .group, name: "Study", operationID: "recreate", scope: scope, now: 3)
        _ = try await repository.executeTodoTool(request, operationID: "delete", scope: scope, now: 4, today: 10)
        let snapshot = try await repository.snapshot(scope: scope, clock: clock())
        XCTAssertEqual(snapshot.categories, [recreated])
    }

    func testAnotherUserTurnCannotReuseOperationReceipt() async throws {
        let repository = try repository()
        let scope = try await repository.open(ownerKey: "owner", clock: clock())
        _ = try await create(repository, scope: scope)
        var command = NivoTodoToolCommand(action: "create", identity: identity, patch: NivoTodoToolPatch(title: "Read"))
        command.identity.messageID = "another-user"
        do {
            _ = try await repository.executeTodoTool(command, operationID: "create", scope: scope, now: 2, today: 10)
            XCTFail("不能复用另一用户回合的回执")
        } catch { XCTAssertEqual(error as? NivoLifeError, .operationConflict) }
    }

    func testPauseToolRetryDoesNotRecalculateElapsedDuration() async throws {
        let repository = try repository()
        let scope = try await repository.open(ownerKey: "owner", clock: clock())
        let start = NivoFocusToolCommand(action: "start", identity: identity, title: "Read", minutes: 3)
        let first = try await repository.executeFocusTool(start, operationID: "start", scope: scope, clock: clock())
        let pause = NivoFocusToolCommand(action: "pause", identity: identity, targetID: first.id, expectedRevision: first.revision)
        let paused = try await repository.executeFocusTool(pause, operationID: "pause", scope: scope, clock: clock(38_000))
        let replay = try await repository.executeFocusTool(pause, operationID: "pause", scope: scope, clock: clock(300_000))
        XCTAssertEqual(paused, replay)
        XCTAssertEqual(paused.status, .paused)
        XCTAssertEqual(paused.elapsedMs, 38_000)
        XCTAssertNil(paused.endedAt)
        let snapshot = try await repository.snapshot(scope: scope, clock: clock(300_000))
        XCTAssertEqual(snapshot.focusSpans.count, 1)
        XCTAssertTrue(snapshot.focusSessions[0].isActive)
    }

    func testCompletionUsesRequestedDateAndFrozenTags() async throws {
        let repository = try repository()
        let scope = try await repository.open(ownerKey: "owner", clock: clock())
        let first = try await create(repository, scope: scope)
        let command = NivoTodoToolCommand(action: "complete", identity: identity, targetID: first.id,
            expectedRevision: 1, completedDay: 8, userQuote: "已经完成了")
        let completed = try task(await repository.executeTodoTool(command, operationID: "complete", scope: scope, now: 5, today: 10))
        XCTAssertEqual(completed.completedDay, 8)
        XCTAssertEqual(completed.status, .done)
    }

    func testStrictInputRejectsBooleanAndFractionalIntegers() throws {
        let invalidValues: [Any] = [true, 1.5, "25", NSNull()]
        for value in invalidValues {
            XCTAssertThrowsError(try NivoLifeToolInput.integer(["value": value], "value"))
        }
        XCTAssertEqual(try NivoLifeToolInput.integer(["value": 25], "value"), 25)
    }

    func testMalformedPayloadAndUnknownFieldsAreRejected() throws {
        for raw in ["broken", "[]", "null", #"{"status":"done"}"#, #"{"isImportant":1}"#, #"{"tags":"Study"}"#] {
            XCTAssertThrowsError(try NivoLifeToolInput.patch(["payload": raw]), raw)
        }
    }

    func testBooleanFieldsAcceptJSONBooleansButRejectNumericFlags() throws {
        let patch = try NivoLifeToolInput.patch(["payload": #"{"isImportant":true,"isUrgent":false}"#])
        XCTAssertEqual(patch.isImportant, true)
        XCTAssertEqual(patch.isUrgent, false)
        for flag in ["0", "1", "1.0", "\"true\"", "null"] {
            XCTAssertThrowsError(try NivoLifeToolInput.patch(["payload": "{\"isImportant\":" + flag + "}"]))
        }
        for flag in ["true", "false"] {
            let values = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(("{\"value\":" + flag + "}").utf8)) as? [String: Any])
            XCTAssertThrowsError(try NivoLifeToolInput.integer(values, "value"))
        }
    }

    func testDatePatchDistinguishesMissingAndExplicitNull() throws {
        var task = NivoTodoTask(title: "Read", scheduledDay: 10, dueDay: 20)
        let unchanged = try NivoLifeToolInput.patch(["payload": #"{"title":"New"}"#])
        unchanged.apply(to: &task)
        XCTAssertEqual(task.scheduledDay, 10)
        let changed = try NivoLifeToolInput.patch(["payload": #"{"scheduledDate":null,"dueDate":"2026-11-14"}"#])
        changed.apply(to: &task)
        XCTAssertNil(task.scheduledDay)
        XCTAssertEqual(task.dueDay, try NivoLifeToolInput.day("2026-11-14"))
        XCTAssertThrowsError(try NivoLifeToolInput.day("2026-02-30"))
        XCTAssertThrowsError(try NivoLifeToolInput.day(123))
    }

    func testReplayFlagIsTrueEvenWhenCurrentRevisionHasNotChanged() async throws {
        let repository = try repository()
        let scope = try await repository.open(ownerKey: "owner", clock: clock())
        let request = NivoFocusToolCommand(action: "start", identity: identity, title: "Read", minutes: 3)
        let first = try await repository.executeFocusToolResult(request, operationID: "start", scope: scope, clock: clock())
        let replay = try await repository.executeFocusToolResult(request, operationID: "start", scope: scope, clock: clock(38_000))
        XCTAssertFalse(first.isReplay)
        XCTAssertTrue(replay.isReplay)
        XCTAssertEqual(first.value, replay.value)
        let snapshot = try await repository.snapshot(scope: scope, clock: clock(38_000))
        XCTAssertEqual(snapshot.focusSessions.count, 1)
    }

    func testUnexpectedActionFieldsCannotBeSilentlyIgnored() throws {
        XCTAssertThrowsError(try NivoLifeToolInput.requireFields(
            ["action": "pause", "operationId": "operation", "minutes": 3],
            allowed: ["action", "operationId", "targetId", "expectedRevision"]))
        XCTAssertNoThrow(try NivoLifeToolInput.requireFields(
            ["action": "pause", "operationId": "operation"],
            allowed: ["action", "operationId", "targetId", "expectedRevision"]))
    }
}
