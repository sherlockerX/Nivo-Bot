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

    func testCompletedTaskCannotStartAnotherFocusFromTaskDetails() {
        let target = NivoLifeItemTarget(id: task.id, scope: scope)
        XCTAssertEqual(destination(target: target, sessions: []), .unavailable)
        XCTAssertEqual(task.status, .done)
    }

    func testPickerSearchDoesNotLeakClosedDeletedOrForeignTasks() {
        var open = task
        open.id = "open"
        open.title = " Read science "
        open.status = .inProgress
        var foreign = open
        foreign.ownerKey = "other"
        var removed = open
        removed.deletedAt = 2
        let tasks = [task, foreign, removed, open]
        let result = NivoFocusTaskChoices(tasks: tasks, owner: scope.ownerKey, query: "  READ   ")
        XCTAssertEqual(result.matches.map(\.id), ["open"])
        XCTAssertTrue(result.canCreate)
        XCTAssertFalse(NivoFocusTaskChoices(tasks: tasks, owner: scope.ownerKey, query: "read SCIENCE").canCreate)
        XCTAssertFalse(NivoFocusTaskChoices(tasks: [], owner: scope.ownerKey, query: "   ").canCreate)
        XCTAssertFalse(NivoFocusTaskChoices(tasks: [], owner: scope.ownerKey, query: String(repeating: "x", count: 501)).canCreate)
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

/// 直接运行界面使用的异步消费者，以可控挂起点验证新请求不会丢失或忙等。
@MainActor
final class NivoLifeRequestDrainTests: XCTestCase {
    private let scope = NivoLifeScope(ownerKey: "local", generation: 7)

    func testNewTargetArrivingDuringReadIsHandledWithoutAnotherNavigationEvent() async {
        await assertReplacementIsDrained(NivoLifeItemTarget(id: "second", scope: scope))
    }

    func testSameSessionInNewAccountGenerationIsHandledAfterOldRead() async {
        await assertReplacementIsDrained(NivoLifeItemTarget(id: "first",
            scope: NivoLifeScope(ownerKey: "local", generation: 8)))
    }

    /// 同一目标未消费时结束本轮，后续真实页面事件仍可重新尝试。
    func testUnconsumedTargetDoesNotRetryForeverAndCanResumeLater() async {
        let drain = NivoLifeRequestDrain()
        let target = NivoLifeItemTarget(id: "first", scope: scope)
        var pending: NivoLifeItemTarget? = target
        var handled: [NivoLifeItemTarget] = []
        await drain.run(next: { pending }) { handled.append($0) }
        XCTAssertEqual(handled, [target])
        XCTAssertEqual(pending, target)
        XCTAssertFalse(drain.isRunning)
        await drain.run(next: { pending }) { value in
            handled.append(value)
            pending = nil
        }
        XCTAssertEqual(handled, [target, target])
        XCTAssertNil(pending)
        XCTAssertFalse(drain.isRunning)
    }

    /// 编辑器或面板占用展示位置时不消费请求，关闭之后才继续。
    func testPresentationBlockKeepsPendingTargetUntilDismissal() async {
        let drain = NivoLifeRequestDrain()
        var canPresent = false
        let target = NivoLifeItemTarget(id: "first", scope: scope)
        var pending: NivoLifeItemTarget? = target
        await drain.run(next: { canPresent ? pending : nil }) { _ in XCTFail("当前弹层关闭前不能开始新导航") }
        XCTAssertEqual(pending, target)
        canPresent = true
        var handled: NivoLifeItemTarget?
        await drain.run(next: { canPresent ? pending : nil }) { value in
            handled = value
            pending = nil
        }
        XCTAssertEqual(handled, target)
        XCTAssertNil(pending)
    }

    /// 第一轮真正挂起后才替换目标，第二次调用必须由既有消费者接管。
    private func assertReplacementIsDrained(_ replacement: NivoLifeItemTarget) async {
        let drain = NivoLifeRequestDrain()
        let initial = NivoLifeItemTarget(id: "first", scope: scope)
        var pending: NivoLifeItemTarget? = initial
        var handled: [NivoLifeItemTarget] = []
        let started = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let worker = Task { @MainActor in
            await drain.run(next: { pending }) { target in
                handled.append(target)
                if target == initial {
                    started.continuation.yield(())
                    for await _ in release.stream { break }
                }
                if pending == target { pending = nil }
            }
        }
        for await _ in started.stream { break }
        pending = replacement
        await drain.run(next: { pending }) { _ in XCTFail("并行调用不能再启动第二个消费者") }
        release.continuation.yield(())
        await worker.value
        started.continuation.finish()
        release.continuation.finish()
        XCTAssertEqual(handled, [initial, replacement])
        XCTAssertNil(pending)
        XCTAssertFalse(drain.isRunning)
    }
}
