import XCTest
@testable import Minis

/// 验证从安卓迁移的数据边界，时钟固定以复现暂停、恢复和跨午夜行为。
final class NivoLifeRulesTests: XCTestCase {
    private func clock(_ elapsed: Int64, wall: Int64? = nil, boot: String = "boot-a") -> NivoFocusClockSample {
        NivoFocusClockSample(wallMs: wall ?? (1_000_000 + elapsed), elapsedMs: elapsed, bootID: boot)
    }

    private func timer(mode: NivoFocusMode = .pomodoro) throws -> NivoFocusSession {
        try NivoFocusRules.start(owner: "local", id: "session", title: "Read", task: nil,
                                 mode: mode, minutes: 3, clock: clock(0))
    }

    func testPauseDoesNotInventTargetDuration() throws {
        let result = try NivoFocusRules.mutate(timer(), action: "pause", expectedRevision: 1,
                                               clock: clock(1_000), spanID: "span-1")
        XCTAssertEqual(result.session.status, .paused)
        XCTAssertEqual(result.session.elapsedMs, 1_000)
        XCTAssertNil(result.session.endedAt)
        XCTAssertEqual(result.span?.durationMs, 1_000)
    }

    func testResumeExcludesPausedTimeAndClockCorrection() throws {
        let paused = try NivoFocusRules.mutate(timer(), action: "pause", expectedRevision: 1,
                                               clock: clock(10_000), spanID: "first")
        let resumed = try NivoFocusRules.mutate(paused.session, action: "resume", expectedRevision: 2,
                                                clock: clock(50_000, wall: 3_000_000), spanID: "unused")
        XCTAssertNil(resumed.span)
        let finished = try NivoFocusRules.mutate(resumed.session, action: "finish", expectedRevision: 3,
                                                 clock: clock(55_000, wall: 500_000), spanID: "second")
        XCTAssertEqual(finished.session.elapsedMs, 15_000)
        XCTAssertEqual(finished.span?.durationMs, 5_000)
    }

    func testDelayedDeadlineDoesNotOvercount() throws {
        let result = try NivoFocusRules.mutate(timer(), action: "pause", expectedRevision: 1,
                                               clock: clock(500_000), spanID: "deadline")
        XCTAssertEqual(result.session.status, .finished)
        XCTAssertEqual(result.session.elapsedMs, 180_000)
        XCTAssertEqual(result.session.endedAt, 1_180_000)
    }

    func testRebootDoesNotAccumulateUnknownTime() throws {
        let result = try NivoFocusRules.mutate(timer(), action: "pause", expectedRevision: 1,
                                               clock: clock(100_000, boot: "boot-b"), spanID: "unused")
        XCTAssertEqual(result.session.status, .paused)
        XCTAssertEqual(result.session.elapsedMs, 0)
        XCTAssertNil(result.span)
    }

    func testFocusRejectsStaleRevisionAndDeletionWhileRunning() throws {
        let session = try timer()
        XCTAssertThrowsError(try NivoFocusRules.mutate(session, action: "pause", expectedRevision: 0,
                                                       clock: clock(1_000), spanID: "span")) { error in
            XCTAssertEqual(error as? NivoLifeError, .staleRevision(expected: 0, actual: 1))
        }
        XCTAssertThrowsError(try NivoFocusRules.mutate(session, action: "delete", expectedRevision: 1,
                                                       clock: clock(1_000), spanID: "span"))
    }

    func testFocusSnapshotsTaskAndDoesNotCompleteIt() throws {
        let task = NivoTodoTask(ownerKey: "local", id: "task", title: "Original", groupName: "Work", tags: ["Study"])
        let session = try NivoFocusRules.start(owner: "local", id: "timer", title: "Ignored", task: task,
                                               mode: .stopwatch, minutes: 25, clock: clock(0))
        XCTAssertEqual(session.title, "Original")
        XCTAssertEqual(session.tags, ["Study"])
        XCTAssertEqual(session.targetMs, 43_200_000)
        XCTAssertEqual(task.status, .todo)
    }

    func testStatisticsUsesIntersectionAndExcludesRestDeletedAndUnfinished() throws {
        var finished = try timer()
        finished.status = .finished
        var rest = finished
        rest.id = "rest"
        rest.mode = .rest
        var deleted = finished
        deleted.id = "deleted"
        deleted.deletedAt = 1
        var running = finished
        running.id = "running"
        running.status = .running
        let sessions = [finished, rest, deleted, running]
        let spans = sessions.map { NivoFocusSpan(id: $0.id, sessionId: $0.id, startedAt: 900, durationMs: 300) }
        XCTAssertEqual(NivoFocusRules.duration(sessions: sessions, spans: spans, startMs: 1_000, endMs: 1_100), 100)
    }

    func testTaskCompletionFreezesTagsUntilReopened() throws {
        let input = NivoTodoTask(ownerKey: "local", title: "Report", status: .done, tags: ["Work"])
        let completed = try NivoTodoRules.update(input, previous: nil, owner: "local", id: "task", now: 10, today: 20)
        var edit = completed
        edit.tags = ["Personal"]
        let changed = try NivoTodoRules.update(edit, previous: completed, owner: "local", id: "task", now: 30, today: 21)
        XCTAssertEqual(changed.completionTags, ["Work"])
        XCTAssertEqual(changed.completedDay, 20)
        edit.status = .todo
        let reopened = try NivoTodoRules.update(edit, previous: changed, owner: "local", id: "task", now: 40, today: 21)
        XCTAssertNil(reopened.completedDay)
        XCTAssertNil(reopened.completedAt)
        XCTAssertEqual(reopened.completionTags, [])
    }

    func testTaskRejectsFutureCompletionAndWrongAccount() throws {
        let input = NivoTodoTask(ownerKey: "local", title: "Report", status: .done, completedDay: 21)
        XCTAssertThrowsError(try NivoTodoRules.update(input, previous: nil, owner: "local", id: "task", now: 10, today: 20))
        XCTAssertThrowsError(try NivoTodoRules.update(input, previous: nil, owner: "other", id: "task", now: 10, today: 20))
    }

    func testTaskClockRollbackKeepsArchiveReadableWithoutInventingCompletionTime() throws {
        let input = NivoTodoTask(ownerKey: "local", title: "Report")
        let created = try NivoTodoRules.update(input, previous: nil, owner: "local", id: "task", now: 100, today: 20)
        var edit = created
        edit.status = .done
        let completed = try NivoTodoRules.update(edit, previous: created, owner: "local", id: "task", now: 50, today: 20)
        XCTAssertEqual(completed.updatedAt, 100)
        XCTAssertEqual(completed.completedAt, 50)
        XCTAssertEqual(completed.revision, 2)
        var state = NivoLifeState(ownerKey: "local")
        state.tasks = [completed]
        XCTAssertNoThrow(try NivoLifeValidation.validate(state, owner: "local"))
    }

    func testTagsPreserveOrderAndCategoryCase() throws {
        XCTAssertEqual(try NivoTodoRules.tags([" Work ", "Study", "Work", "work", ""]), ["Work", "Study", "work"])
        XCTAssertThrowsError(try NivoTodoRules.categoryName("Work\nHome", kind: .group))
        XCTAssertThrowsError(try NivoTodoRules.validateOperationID("../escape"))
    }
}
