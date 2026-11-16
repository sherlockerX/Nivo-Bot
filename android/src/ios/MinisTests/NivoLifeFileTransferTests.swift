import XCTest
@testable import Minis

/// 使用临时仓库验证跨平台备份与原子恢复，不接触正式任务和专注记录。
@MainActor
final class NivoLifeFileTransferTests: XCTestCase {
    private let clock = NivoFocusClockSample(wallMs: 1_000_000, elapsedMs: 100, bootID: "fixture")

    private func repository(writer: NivoLifeRepository.Writer? = nil) throws -> NivoLifeRepository {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        if let writer { return NivoLifeRepository(directory: root, writer: writer) }
        return NivoLifeRepository(directory: root)
    }

    private func backup(title: String = "Read", id: String = "task", done: Bool = false) throws -> Data {
        let task = NivoTodoTask(ownerKey: "android-owner", id: id, title: title,
            status: done ? .done : .todo, groupName: "Study", tags: ["Growth"], revision: 1,
            createdAt: 10, updatedAt: 20, completedDay: done ? 0 : nil,
            completedAt: done ? 20 : nil, completionTags: done ? ["Growth"] : [])
        return try JSONEncoder().encode(NivoTodoBackupDocument(tasks: [task], categories: [], links: [],
                                                              history: NivoTodoBackupHistory()))
    }

    func testImportKeepsExistingTasksAndRebindsNewTasks() async throws {
        let repository = try repository()
        let scope = try await repository.open(ownerKey: "iphone-owner", clock: clock)
        let local = try await repository.saveTask(NivoTodoTask(ownerKey: scope.ownerKey, title: "Local"),
            operationID: "local", scope: scope, now: 100, today: 0)
        let conflict = try backup(title: "Overwrite", id: local.id)
        let kept = try await repository.importTasks(conflict, scope: scope, now: clock.wallMs, today: 0)
        XCTAssertEqual(kept, NivoTodoImportResult(imported: 0, keptLocal: 1, missingEntries: 0))
        let added = try await repository.importTasks(backup(done: true), scope: scope, now: clock.wallMs, today: 0)
        XCTAssertEqual(added.imported, 1)
        let state = try await repository.snapshot(scope: scope, clock: clock)
        XCTAssertEqual(state.tasks.first { $0.id == local.id }?.title, "Local")
        XCTAssertEqual(state.tasks.first { $0.id == "task" }?.ownerKey, scope.ownerKey)
        XCTAssertEqual(state.tasks.first { $0.id == "task" }?.completionTags, ["Growth"])
        XCTAssertTrue(state.categories.contains { $0.kind == .group && $0.name == "Study" })
        XCTAssertTrue(state.categories.contains { $0.kind == .tag && $0.name == "Growth" })
    }

    func testExactImportReplayDoesNotDuplicateTasksOrHistory() async throws {
        let source = try repository()
        let sourceScope = try await source.open(ownerKey: "source", clock: clock)
        let created = try await source.saveTask(NivoTodoTask(ownerKey: "source", title: "Read"),
            operationID: "create", scope: sourceScope, now: 10, today: 0)
        _ = try await source.changeTaskStatus(id: created.id, status: .done, expectedRevision: 1,
            operationID: "complete", scope: sourceScope, now: 20, today: 0)
        let data = try await source.exportTasks(scope: sourceScope, clock: clock)
        let target = try repository()
        let scope = try await target.open(ownerKey: "target", clock: clock)
        let first = try await target.importTasks(data, scope: scope, now: clock.wallMs, today: 0)
        let second = try await target.importTasks(data, scope: scope, now: clock.wallMs + 1, today: 0)
        XCTAssertEqual(first, second)
        let state = try await target.snapshot(scope: scope, clock: clock)
        XCTAssertEqual(state.tasks.count, 1)
        XCTAssertEqual(state.todoHistory?.events.count, 2)
        XCTAssertNotNil(state.todoHistory?.iosReceipts["complete"])
        XCTAssertNil(state.operations["complete"])
        XCTAssertEqual(state.operations.count, 1)
    }

    func testMissingFragmentsAreReportedWithoutCreatingDiaryEntries() async throws {
        let repository = try repository()
        let scope = try await repository.open(ownerKey: "owner", clock: clock)
        var document = try NivoTodoBackupCodec.decode(backup(), owner: "owner", now: clock.wallMs, today: 0)
        document.links = [NivoTodoBackupLink(entryId: "missing", taskId: "task", title: "Old title",
                                             statusSnapshot: .inProgress, linkedAt: 20)]
        let result = try await repository.importTasks(JSONEncoder().encode(document), scope: scope, now: clock.wallMs, today: 0)
        let snapshot = try await repository.snapshot(scope: scope, clock: clock)
        XCTAssertEqual(result.missingEntries, 1)
        XCTAssertTrue(snapshot.mosaic?.entries.isEmpty ?? true)
    }

    func testFutureCompletionRejectsTheWholeFile() async throws {
        let repository = try repository()
        let scope = try await repository.open(ownerKey: "owner", clock: clock)
        var document = try NivoTodoBackupCodec.decode(backup(done: true), owner: "owner", now: clock.wallMs, today: 0)
        document.tasks[0].completedAt = clock.wallMs + 1
        do {
            _ = try await repository.importTasks(JSONEncoder().encode(document), scope: scope, now: clock.wallMs, today: 0)
            XCTFail("未来的完成记录不得导入")
        } catch { XCTAssertEqual(error as? NivoLifeError, .corruptStore) }
        let state = try await repository.snapshot(scope: scope, clock: clock)
        XCTAssertTrue(state.tasks.isEmpty)
        XCTAssertTrue(state.categories.isEmpty)
    }

    func testDiskFailureLeavesNoPartialImport() async throws {
        let repository = try repository(writer: { _, _ in throw CocoaError(.fileWriteOutOfSpace) })
        let scope = try await repository.open(ownerKey: "owner", clock: clock)
        do {
            _ = try await repository.importTasks(backup(), scope: scope, now: clock.wallMs, today: 0)
            XCTFail("磁盘失败必须向调用者报告")
        } catch { XCTAssertTrue(error is CocoaError) }
        let state = try await repository.snapshot(scope: scope, clock: clock)
        XCTAssertTrue(state.tasks.isEmpty)
        XCTAssertTrue(state.operations.isEmpty)
    }

    func testExportMetersOnlyElapsedFocusTimeAndKeepsTimerRunning() async throws {
        let repository = try repository()
        let scope = try await repository.open(ownerKey: "owner", clock: clock)
        _ = try await repository.startFocus(title: "Read", taskID: nil, mode: .pomodoro, minutes: 3,
            operationID: "start", scope: scope, clock: clock)
        let later = NivoFocusClockSample(wallMs: clock.wallMs + 2_000, elapsedMs: clock.elapsedMs + 2_000, bootID: clock.bootID)
        let data = try await repository.exportFocus(scope: scope, clock: later)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let rows = try XCTUnwrap(json["sessions"] as? [[String: Any]])
        XCTAssertEqual(rows.first?["elapsedMs"] as? Int, 2_000)
        XCTAssertEqual(rows.first?["status"] as? String, "paused")
        let live = try await repository.snapshot(scope: scope, clock: later)
        XCTAssertEqual(live.focusSessions.first?.status, .running)
        XCTAssertEqual(live.focusSessions.first?.elapsedMs, 0)
        XCTAssertTrue(live.focusSpans.isEmpty)
    }

    func testAndroidV1DefaultsNonessentialFieldsButRejectsWrongTypes() throws {
        let raw = #"{"format":"nanomuse-todo","version":1,"tasks":[{"id":"legacy","title":"Read","status":"todo","tags":[],"revision":1,"createdAt":10,"updatedAt":20}]}"#
        let document = try NivoTodoBackupCodec.decode(Data(raw.utf8), owner: "current", now: 30, today: 0)
        XCTAssertEqual(document.tasks.first?.ownerKey, "current")
        XCTAssertEqual(document.tasks.first?.completionTags, [])
        XCTAssertEqual(document.tasks.first?.isImportant, false)
        let invalid = raw.replacingOccurrences(of: #""tags":[]"#, with: #""tags":"Study""#)
        XCTAssertThrowsError(try NivoTodoBackupCodec.decode(Data(invalid.utf8), owner: "current", now: 30, today: 0))
    }

    func testExportedEventsHaveAndroidCompatibleArchivalReceipts() async throws {
        let repository = try repository()
        let scope = try await repository.open(ownerKey: "owner", clock: clock)
        let created = try await repository.saveTask(NivoTodoTask(ownerKey: "owner", title: "Before", tags: ["Study"]),
            operationID: "create", scope: scope, now: 10, today: 0)
        _ = try await repository.changeTaskStatus(id: created.id, status: .done, expectedRevision: 1,
            operationID: "done", scope: scope, now: 20, today: 0)
        let data = try await repository.exportTasks(scope: scope, clock: clock)
        let document = try NivoTodoBackupCodec.decode(data, owner: "other", now: clock.wallMs, today: 0)
        XCTAssertEqual(document.events.count, 2)
        for event in document.events {
            let operation = try XCTUnwrap(document.operations.first { $0.operationId == event.operationId })
            let request = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(operation.request.utf8)) as? [String: Any])
            XCTAssertEqual(request["kind"] as? String, "save")
            XCTAssertEqual(request["origin"] as? String, "ios-history")
            let snapshot = try JSONDecoder().decode(NivoTodoTask.self, from: Data(operation.result.utf8))
            XCTAssertEqual(snapshot.id, event.taskId)
            XCTAssertEqual(snapshot.status.rawValue, event.status)
        }
        XCTAssertEqual(document.events.first?.snapshot?.status, .todo)
        XCTAssertEqual(document.events.last?.snapshot?.completionTags, ["Study"])
    }

    func testPersistedHistoryRejectsOrphansAndDuplicateIdentities() throws {
        var state = NivoLifeState(ownerKey: "owner")
        let task = NivoTodoTask(ownerKey: "owner", id: "task", title: "Read", revision: 1, createdAt: 10, updatedAt: 20)
        state.tasks = [task]
        let event = NivoTodoHistoryEvent(operationId: "event", taskId: task.id, status: "todo", tags: [], createdAt: 20)
        state.todoHistory = NivoTodoBackupHistory(events: [event, event])
        XCTAssertThrowsError(try NivoLifeValidation.validate(state, owner: "owner"))
        state.todoHistory = NivoTodoBackupHistory(events: [event])
        state.tasks = []
        XCTAssertThrowsError(try NivoLifeValidation.validate(state, owner: "owner"))
    }
}
