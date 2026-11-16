import XCTest
@testable import Minis

/// 以实际页面使用的选择规则验证冷启动、任务联动与账户边界。
final class NivoLifeEntryRulesTests: XCTestCase {
    private let scope = NivoLifeScope(ownerKey: "local", generation: 7)
    private var task: NivoTodoTask { NivoTodoTask(ownerKey: "local", id: "task", title: "Read", status: .done) }

    func testFinishedNotificationOpensItsRecordInsteadOfAnotherActiveTimer() throws {
        let finished = try session("finished", status: .finished)
        let running = try session("running")
        XCTAssertEqual(destination(requested: finished.id, sessions: [running, finished]), .session(finished.id))
    }

    func testMissingDeletedAndForeignNotificationNeverFallsBackToActiveTimer() throws {
        let running = try session("running")
        var deleted = try session("deleted", status: .finished)
        deleted.deletedAt = 10
        var foreign = try session("foreign", status: .finished)
        foreign.ownerKey = "other"
        for identifier in ["missing", "deleted", "foreign"] {
            XCTAssertEqual(destination(requested: identifier, sessions: [running, deleted, foreign]), .unavailable)
        }
    }

    func testImmersiveRestoreKeepsCompletionAfterCountdownExpires() throws {
        let finished = try session("finished", status: .finished)
        XCTAssertEqual(destination(stored: finished.id, sessions: [finished]), .session(finished.id))
        XCTAssertEqual(destination(stored: "old", sessions: [try session("running")]), .none)
        XCTAssertEqual(destination(sessions: [try session("running")], restore: false), .none)
    }

    func testCompletedTaskCanPrepareFocusWithoutChangingTaskStatus() {
        let target = NivoLifeItemTarget(id: task.id, scope: scope)
        XCTAssertEqual(destination(target: target, sessions: []), .task(task.id))
        XCTAssertEqual(task.status, .done)
    }

    func testTaskEntryReturnsMatchingPausedTimerAndRejectsAnotherTaskTimer() throws {
        let target = NivoLifeItemTarget(id: task.id, scope: scope)
        let paused = try session("paused", status: .paused)
        XCTAssertEqual(destination(target: target, sessions: [paused]), .session(paused.id))
        var otherTask = paused
        otherTask.taskId = "other-task"
        XCTAssertEqual(destination(target: target, sessions: [otherTask]), .busy)
    }

    func testTaskEntryRejectsOldAccountGenerationAndDeletedTask() {
        let old = NivoLifeItemTarget(id: task.id, scope: NivoLifeScope(ownerKey: "local", generation: 6))
        XCTAssertEqual(destination(target: old, sessions: []), .unavailable)
        var deleted = task
        deleted.deletedAt = 2
        XCTAssertEqual(NivoLifeEntryRules.focusDestination(
            requestedSessionID: nil, requestedTask: NivoLifeItemTarget(id: task.id, scope: scope), storedID: "",
            sessions: [], tasks: [deleted], scope: scope, shouldRestore: true
        ), .unavailable)
    }

    func testTaskHistoryExcludesRunningBreakDeletedAndForeignSessions() throws {
        let finished = try session("finished", status: .finished)
        var latest = finished
        latest.id = "latest"
        latest.startedAt += 1_000
        let running = try session("running")
        var rest = finished
        rest.mode = .rest
        var deleted = finished
        deleted.deletedAt = 1
        var foreign = finished
        foreign.ownerKey = "other"
        var unrelated = finished
        unrelated.taskId = "unrelated"
        let result = NivoLifeEntryRules.finishedFocus(for: task, sessions: [finished, running, rest, deleted, foreign, unrelated, latest])
        XCTAssertEqual(result.map(\.id), ["latest", "finished"])
    }

    func testTaskFragmentsKeepSnapshotLinksAndExcludeTrashAndForeignOwner() {
        let linked = fragment("linked", day: 10)
        var snapshotOnly = fragment("snapshot", day: 12)
        snapshotOnly.taskIDs = []
        snapshotOnly.taskSnapshots = [NivoMosaicTaskLink(id: task.id, title: "Old title", status: .inProgress)]
        var deleted = fragment("deleted", day: 13)
        deleted.deletedAt = 1
        var foreign = fragment("foreign", day: 13)
        foreign.ownerKey = "other"
        var unrelated = fragment("unrelated", day: 13)
        unrelated.taskIDs = []
        XCTAssertEqual(NivoLifeEntryRules.linkedFragments(for: task, entries: [linked, deleted, foreign, unrelated, snapshotOnly]).map(\.id),
                       ["snapshot", "linked"])
    }

    private func destination(requested: String? = nil, target: NivoLifeItemTarget? = nil, stored: String = "",
                             sessions: [NivoFocusSession], restore: Bool = true) -> NivoFocusDestination {
        NivoLifeEntryRules.focusDestination(requestedSessionID: requested, requestedTask: target, storedID: stored,
            sessions: sessions, tasks: [task], scope: scope, shouldRestore: restore)
    }

    private func session(_ id: String, status: NivoFocusStatus = .running) throws -> NivoFocusSession {
        var result = try NivoFocusRules.start(owner: scope.ownerKey, id: id, title: "Read", task: task,
            mode: .pomodoro, minutes: 3, clock: NivoFocusClockSample(wallMs: 1_000, elapsedMs: 500, bootID: "boot"))
        result.status = status
        return result
    }

    private func fragment(_ id: String, day: Int64) -> NivoMosaicEntry {
        NivoMosaicEntry(ownerKey: scope.ownerKey, id: id, day: day, text: "Note", taskIDs: [task.id],
            focusIDs: [], createdAt: 1_000, updatedAt: 1_000)
    }
}
