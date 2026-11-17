import XCTest
@testable import Minis

/// 真实临时文件验证碎片与待办的事务边界，不写入用户学习或生活档案。
@MainActor
final class NivoMosaicRepositoryTests: XCTestCase {
    private func repository() throws -> NivoLifeRepository {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nivo-mosaic-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return NivoLifeRepository(directory: directory)
    }

    private let clock = NivoFocusClockSample(wallMs: 1_000_000, elapsedMs: 1_000, bootID: "test")

    private func draft(owner: String = "local") -> NivoMosaicDraft {
        NivoMosaicDraft(ownerKey: owner, id: "draft-one", day: 10, text: "Finished the chapter.", updatedAt: 100)
    }

    func testDraftDoesNotChangeTaskStatus() async throws {
        let repository = try repository()
        let scope = try await repository.open(ownerKey: "local", clock: clock)
        let task = try await repository.saveTask(NivoTodoTask(ownerKey: "local", title: "Read"), operationID: "task", scope: scope, now: 1, today: 10)
        var candidate = draft()
        candidate.taskIDs = [task.id]
        candidate.taskSelections = [NivoTodoSelection(taskId: task.id, expectedRevision: task.revision, requestedStatus: .done)]
        _ = try await repository.saveMosaicDraft(candidate, scope: scope)
        let state = try await repository.snapshot(scope: scope, clock: clock)
        XCTAssertEqual(state.tasks.first?.status, .todo)
        XCTAssertEqual(state.mosaic?.drafts.count, 1)
        XCTAssertEqual(state.mosaic?.entries.count, 0)
    }

    func testStaleLinkedTaskRollsBackEntireSaveAndKeepsDraft() async throws {
        let repository = try repository()
        let scope = try await repository.open(ownerKey: "local", clock: clock)
        let first = try await repository.saveTask(NivoTodoTask(ownerKey: "local", title: "First"), operationID: "first", scope: scope, now: 1, today: 10)
        let second = try await repository.saveTask(NivoTodoTask(ownerKey: "local", title: "Second"), operationID: "second", scope: scope, now: 1, today: 10)
        var candidate = draft()
        candidate.taskIDs = [first.id, second.id]
        candidate.taskSelections = [first, second].map { NivoTodoSelection(taskId: $0.id, expectedRevision: $0.revision, requestedStatus: .done) }
        _ = try await repository.saveMosaicDraft(candidate, scope: scope)
        _ = try await repository.changeTaskStatus(id: second.id, status: .inProgress, expectedRevision: second.revision,
                                                  operationID: "changed", scope: scope, now: 2, today: 10)
        do {
            _ = try await repository.saveMosaic(candidate, operationID: "save", scope: scope, now: 3, today: 10)
            XCTFail("任何关联任务冲突都必须整体回滚")
        } catch { XCTAssertEqual(error as? NivoLifeError, .staleRevision(expected: 1, actual: 2)) }
        let state = try await repository.snapshot(scope: scope, clock: clock)
        XCTAssertEqual(state.tasks.first { $0.id == first.id }?.status, .todo)
        XCTAssertEqual(state.tasks.first { $0.id == second.id }?.status, .inProgress)
        XCTAssertTrue(state.mosaic?.entries.isEmpty == true)
        XCTAssertEqual(state.mosaic?.drafts.first, candidate)
        XCTAssertNil(state.operations["save"])
    }

    func testExactRetryReturnsSameEntryAndDoesNotCompleteTaskTwice() async throws {
        let repository = try repository()
        let scope = try await repository.open(ownerKey: "local", clock: clock)
        let task = try await repository.saveTask(NivoTodoTask(ownerKey: "local", title: "Read", tags: ["Growth"]), operationID: "task", scope: scope, now: 1, today: 10)
        var candidate = draft()
        candidate.taskIDs = [task.id]
        candidate.taskSelections = [NivoTodoSelection(taskId: task.id, expectedRevision: task.revision, requestedStatus: .done)]
        let first = try await repository.saveMosaic(candidate, operationID: "save", scope: scope, now: 2, today: 10)
        let repeated = try await repository.saveMosaic(candidate, operationID: "save", scope: scope, now: 999, today: 11)
        XCTAssertEqual(first, repeated)
        let state = try await repository.snapshot(scope: scope, clock: clock)
        XCTAssertEqual(state.mosaic?.entries.count, 1)
        XCTAssertEqual(state.tasks.first?.revision, 2)
        XCTAssertEqual(state.tasks.first?.completionTags, ["Growth"])
        XCTAssertEqual(state.tasks.first?.completedDay, 10)
    }

    func testDeletedOrRestoredFragmentDoesNotUndoTaskCompletion() async throws {
        let repository = try repository()
        let scope = try await repository.open(ownerKey: "local", clock: clock)
        let task = try await repository.saveTask(NivoTodoTask(ownerKey: "local", title: "Read"), operationID: "task", scope: scope, now: 1, today: 10)
        var candidate = draft()
        candidate.taskIDs = [task.id]
        candidate.taskSelections = [NivoTodoSelection(taskId: task.id, expectedRevision: task.revision, requestedStatus: .done)]
        let saved = try await repository.saveMosaic(candidate, operationID: "save", scope: scope, now: 2, today: 10)
        let deleted = try await repository.changeMosaicEntry(id: (try XCTUnwrap(saved.entry)).id, expectedRevision: 1, action: "delete_fragment", operationID: "delete", scope: scope, now: 3)
        _ = try await repository.changeMosaicEntry(id: deleted.id, expectedRevision: 2, action: "restore_fragment", operationID: "restore", scope: scope, now: 4)
        let state = try await repository.snapshot(scope: scope, clock: clock)
        XCTAssertEqual(state.tasks.first?.status, .done)
        XCTAssertEqual(state.tasks.first?.revision, 2)
        XCTAssertNil(state.mosaic?.entries.first?.deletedAt)
        XCTAssertEqual(state.mosaic?.entries.first?.revision, 3)
    }

    /// 修改日记文字不重新解释当时的任务进展，即使任务后来改名或完成。
    func testEditingFragmentKeepsHistoricalTaskSnapshot() async throws {
        let repository = try repository()
        let scope = try await repository.open(ownerKey: "local", clock: clock)
        let task = try await repository.saveTask(NivoTodoTask(ownerKey: "local", title: "Original chapter", status: .inProgress),
            operationID: "task", scope: scope, now: 1, today: 10)
        var candidate = draft()
        candidate.taskIDs = [task.id]
        let saved = try await repository.saveMosaic(candidate, operationID: "save", scope: scope, now: 2, today: 10)
        var changed = task
        changed.title = "Renamed chapter"
        changed.status = .done
        _ = try await repository.saveTask(changed, operationID: "changed", scope: scope, now: 3, today: 10)
        var edit = try NivoMosaicRules.draft(from: XCTUnwrap(saved.entry), now: 4)
        edit.text = "A corrected description."
        let edited = try await repository.saveMosaic(edit, operationID: "edit", scope: scope, now: 4, today: 10)
        XCTAssertEqual((try XCTUnwrap(edited.entry)).taskSnapshots, (try XCTUnwrap(saved.entry)).taskSnapshots)
        let state = try await repository.snapshot(scope: scope, clock: clock)
        XCTAssertEqual(state.tasks.first?.status, .done)
        XCTAssertEqual(state.tasks.first?.revision, 2)
    }

    /// 保留已有历史关联不需要最新任务版本，也不能借机重放状态变更。
    func testKeepingHistoricalLinkIgnoresStaleReadVersion() async throws {
        let repository = try repository()
        let scope = try await repository.open(ownerKey: "local", clock: clock)
        let task = try await repository.saveTask(NivoTodoTask(ownerKey: "local", title: "Read"),
            operationID: "task", scope: scope, now: 1, today: 10)
        var candidate = draft()
        candidate.taskIDs = [task.id]
        let saved = try await repository.saveMosaic(candidate, operationID: "save", scope: scope, now: 2, today: 10)
        _ = try await repository.changeTaskStatus(id: task.id, status: .done, expectedRevision: task.revision,
            operationID: "changed", scope: scope, now: 3, today: 10)
        var edit = try NivoMosaicRules.draft(from: XCTUnwrap(saved.entry), now: 4)
        edit.taskSelections = [NivoTodoSelection(taskId: task.id, expectedRevision: task.revision)]
        let edited = try await repository.saveMosaic(edit, operationID: "edit", scope: scope, now: 4, today: 10)
        XCTAssertEqual((try XCTUnwrap(edited.entry)).taskSnapshots, (try XCTUnwrap(saved.entry)).taskSnapshots)
    }

    /// 用户明确选择新的任务状态时才更新这一条关联的语义快照。
    func testExplicitTaskStatusRefreshesHistoricalSnapshot() async throws {
        let repository = try repository()
        let scope = try await repository.open(ownerKey: "local", clock: clock)
        let task = try await repository.saveTask(NivoTodoTask(ownerKey: "local", title: "Read"),
            operationID: "task", scope: scope, now: 1, today: 10)
        var candidate = draft()
        candidate.taskIDs = [task.id]
        let saved = try await repository.saveMosaic(candidate, operationID: "save", scope: scope, now: 2, today: 10)
        var edit = try NivoMosaicRules.draft(from: XCTUnwrap(saved.entry), now: 3)
        edit.taskSelections = [NivoTodoSelection(taskId: task.id, expectedRevision: task.revision, requestedStatus: .done)]
        let edited = try await repository.saveMosaic(edit, operationID: "edit", scope: scope, now: 3, today: 10)
        XCTAssertEqual((try XCTUnwrap(edited.entry)).taskSnapshots?.first?.status, .done)
        XCTAssertEqual(saved.entry?.taskSnapshots?.first?.linkedAt, 2)
        XCTAssertEqual(edited.entry?.taskSnapshots?.first?.linkedAt, 2)
        XCTAssertEqual(edited.tasks.first?.revision, 2)
        XCTAssertEqual(edited.tasks.first?.completedDay, 10)
    }

    func testRunningFocusCannotBecomeCompletedFocusEvidence() async throws {
        let repository = try repository()
        let scope = try await repository.open(ownerKey: "local", clock: clock)
        let focus = try await repository.startFocus(title: "Read", mode: .stopwatch, minutes: 1, operationID: "focus", scope: scope, clock: clock)
        var candidate = draft()
        candidate.focusIDs = [focus.id]
        do {
            _ = try await repository.saveMosaic(candidate, operationID: "save", scope: scope, now: 3, today: 10)
            XCTFail("运行中的专注不是已完成时段")
        } catch { XCTAssertEqual(error as? NivoLifeError, .invalidField("focus_link")) }
        let finished = try await repository.controlFocus(action: "finish", id: focus.id, expectedRevision: 1, operationID: "finish", scope: scope,
            clock: NivoFocusClockSample(wallMs: 1_005_000, elapsedMs: 6_000, bootID: "test"))
        let saved = try await repository.saveMosaic(candidate, operationID: "save", scope: scope, now: 4, today: 10)
        XCTAssertEqual((try XCTUnwrap(saved.entry)).focusSnapshots?.first?.elapsedMs, finished.elapsedMs)
    }

    func testHabitPauseKeepsPastPlanAndResumeRestoresIt() async throws {
        let repository = try repository()
        let scope = try await repository.open(ownerKey: "local", clock: clock)
        var habit = try await repository.saveMosaicHabit(NivoMosaicHabit(ownerKey: "local", id: "", title: "Read", weekdays: Set(1...7), createdAt: 0),
            operationID: "habit", scope: scope, today: 10, now: 1)
        habit.weekdays = []
        habit = try await repository.saveMosaicHabit(habit, operationID: "pause", scope: scope, today: 12, now: 2)
        XCTAssertTrue(NivoMosaicRules.isPlanned(habit, day: 10))
        XCTAssertFalse(NivoMosaicRules.isPlanned(habit, day: 12))
        habit.weekdays = [1, 2, 3, 4, 5]
        habit = try await repository.saveMosaicHabit(habit, operationID: "resume", scope: scope, today: 15, now: 3)
        XCTAssertTrue(NivoMosaicRules.isPlanned(habit, day: 10))
        XCTAssertFalse(NivoMosaicRules.isPlanned(habit, day: 13))
        XCTAssertEqual(NivoMosaicRules.weekdays(habit, on: 16), Set([1, 2, 3, 4, 5]))
    }

    /// 与安卓一致，只有习惯勾选也可提交，不生成一条没有内容的日记。
    func testHabitOnlySaveMarksDayAndClearsDraftWithoutCreatingFragment() async throws {
        let repository = try repository()
        let scope = try await repository.open(ownerKey: "local", clock: clock)
        let habit = try await saveHabit(repository, scope: scope)
        var candidate = draft()
        candidate.text = ""
        candidate.mood = .good
        candidate.habitID = habit.id
        candidate.shouldMarkHabitDone = true
        _ = try await repository.saveMosaicDraft(candidate, scope: scope)
        let first = try await repository.saveMosaic(candidate, operationID: "save", scope: scope, now: 2, today: 10)
        let repeated = try await repository.saveMosaic(candidate, operationID: "save", scope: scope, now: 3, today: 10)
        XCTAssertEqual(first, repeated)
        XCTAssertNil(first.entry)
        let state = try await repository.mosaicSnapshot(scope: scope)
        XCTAssertTrue(state.entries.isEmpty)
        XCTAssertTrue(state.drafts.isEmpty)
        XCTAssertEqual(state.habitDays?.count, 1)
        XCTAssertEqual(state.habitDays?.first?.status, .done)
        XCTAssertEqual(state.days.first?.mood, .good)
    }

    /// 编辑时明确取消勾选会撤销当天完成标记，不留下看似成功但状态未变的反馈。
    func testUncheckingHabitWhileEditingClearsDoneMark() async throws {
        let repository = try repository()
        let scope = try await repository.open(ownerKey: "local", clock: clock)
        let habit = try await saveHabit(repository, scope: scope)
        var candidate = draft()
        candidate.habitID = habit.id
        candidate.shouldMarkHabitDone = true
        let saved = try await repository.saveMosaic(candidate, operationID: "save", scope: scope, now: 2, today: 10)
        let marks = try await repository.mosaicSnapshot(scope: scope).habitDays ?? []
        var edit = try NivoMosaicRules.draft(from: XCTUnwrap(saved.entry), now: 3, habitDays: marks)
        XCTAssertEqual(edit.shouldMarkHabitDone, true)
        edit.shouldMarkHabitDone = false
        _ = try await repository.saveMosaic(edit, operationID: "edit", scope: scope, now: 3, today: 10)
        let state = try await repository.mosaicSnapshot(scope: scope)
        XCTAssertTrue(state.habitDays?.isEmpty == true)
        XCTAssertEqual(state.entries.count, 1)
    }

    /// 取消完成只撤销完成态，不抹掉用户另行保存的跳过记录。
    func testUncheckingHabitKeepsSeparateSkippedMark() async throws {
        let repository = try repository()
        let scope = try await repository.open(ownerKey: "local", clock: clock)
        let habit = try await saveHabit(repository, scope: scope)
        var candidate = draft()
        candidate.habitID = habit.id
        let saved = try await repository.saveMosaic(candidate, operationID: "save", scope: scope, now: 2, today: 10)
        _ = try await repository.setMosaicHabitDay(habitID: habit.id, day: 10, status: .skipped,
            operationID: "skip", scope: scope, today: 10, now: 3)
        var edit = try NivoMosaicRules.draft(from: XCTUnwrap(saved.entry), now: 4)
        edit.shouldMarkHabitDone = false
        _ = try await repository.saveMosaic(edit, operationID: "edit", scope: scope, now: 4, today: 10)
        let state = try await repository.mosaicSnapshot(scope: scope)
        XCTAssertEqual(state.habitDays?.first?.status, .skipped)
    }

    /// 改期后的打卡归于新日期，旧日期没有其他同习惯记录时不重复累计。
    func testMovingHabitFragmentMovesItsDoneMark() async throws {
        let repository = try repository()
        let scope = try await repository.open(ownerKey: "local", clock: clock)
        let habit = try await saveHabit(repository, scope: scope)
        var candidate = draft()
        candidate.habitID = habit.id
        candidate.shouldMarkHabitDone = true
        let saved = try await repository.saveMosaic(candidate, operationID: "save", scope: scope, now: 2, today: 10)
        var edit = try NivoMosaicRules.draft(from: XCTUnwrap(saved.entry), now: 3)
        edit.day = 11
        edit.shouldMarkHabitDone = true
        _ = try await repository.saveMosaic(edit, operationID: "edit", scope: scope, now: 3, today: 11)
        let state = try await repository.mosaicSnapshot(scope: scope)
        XCTAssertNil(state.habitDays?.first { $0.day == 10 })
        XCTAssertEqual(state.habitDays?.first { $0.day == 11 }?.status, .done)
        XCTAssertNil(state.days.first { $0.day == 10 }?.coverEntryID)
    }

    /// 同一天还有同习惯记录时，移动另一条不能抹掉原日期的完成记录。
    func testMovingHabitFragmentKeepsOldMarkWhenAnotherRecordRemains() async throws {
        let repository = try repository()
        let scope = try await repository.open(ownerKey: "local", clock: clock)
        let habit = try await saveHabit(repository, scope: scope)
        var candidate = draft()
        candidate.habitID = habit.id
        candidate.shouldMarkHabitDone = true
        let first = try await repository.saveMosaic(candidate, operationID: "first", scope: scope, now: 2, today: 10)
        candidate.id = "second-draft"
        _ = try await repository.saveMosaic(candidate, operationID: "second", scope: scope, now: 3, today: 10)
        var edit = try NivoMosaicRules.draft(from: XCTUnwrap(first.entry), now: 4)
        edit.day = 11
        edit.shouldMarkHabitDone = true
        _ = try await repository.saveMosaic(edit, operationID: "move", scope: scope, now: 4, today: 11)
        let state = try await repository.mosaicSnapshot(scope: scope)
        XCTAssertEqual(state.habitDays?.first { $0.day == 10 }?.status, .done)
        XCTAssertEqual(state.habitDays?.first { $0.day == 11 }?.status, .done)
    }

    /// 跨时区后本地日期变早，只改原日记文字仍可保存，不能借此新建未来记录。
    func testExistingFragmentStaysEditableWhenLocalTodayMovesBack() async throws {
        let repository = try repository()
        let scope = try await repository.open(ownerKey: "local", clock: clock)
        let saved = try await repository.saveMosaic(draft(), operationID: "save", scope: scope, now: 1, today: 10)
        var edit = try NivoMosaicRules.draft(from: XCTUnwrap(saved.entry), now: 2)
        edit.text = "Corrected after travelling."
        let result = try await repository.saveMosaic(edit, operationID: "edit", scope: scope, now: 2, today: 9)
        XCTAssertEqual((try XCTUnwrap(result.entry)).text, edit.text)
        edit.expectedRevision = (try XCTUnwrap(result.entry)).revision
        edit.day = 11
        do {
            _ = try await repository.saveMosaic(edit, operationID: "future", scope: scope, now: 3, today: 9)
            XCTFail("已有记录也不能改到另一个未来日期")
        } catch { XCTAssertEqual(error as? NivoLifeError, .invalidField("future_fragment")) }
    }

    /// 清空已有日记不能变成新的空白打卡，也不能丢掉原记录。
    func testClearingExistingFragmentIsRejectedAndKeepsOriginal() async throws {
        let repository = try repository()
        let scope = try await repository.open(ownerKey: "local", clock: clock)
        let habit = try await saveHabit(repository, scope: scope)
        var candidate = draft()
        candidate.habitID = habit.id
        candidate.shouldMarkHabitDone = true
        let saved = try await repository.saveMosaic(candidate, operationID: "save", scope: scope, now: 2, today: 10)
        var edit = try NivoMosaicRules.draft(from: XCTUnwrap(saved.entry), now: 3)
        edit.text = "  "
        edit.shouldMarkHabitDone = true
        XCTAssertFalse(NivoMosaicRules.canSave(edit))
        do {
            _ = try await repository.saveMosaic(edit, operationID: "edit", scope: scope, now: 3, today: 10)
            XCTFail("清空已有记录不得删除原文")
        } catch { XCTAssertEqual(error as? NivoLifeError, .invalidField("empty_fragment")) }
        let state = try await repository.mosaicSnapshot(scope: scope)
        XCTAssertEqual(state.entries, [try XCTUnwrap(saved.entry)])
        XCTAssertEqual(state.habitDays?.first?.status, .done)
    }

    /// 日记可以补记另一日完成的任务，显式日期不会被日记日期覆盖。
    func testFragmentKeepsExplicitTaskCompletionDate() async throws {
        let repository = try repository()
        let scope = try await repository.open(ownerKey: "local", clock: clock)
        let task = try await repository.saveTask(NivoTodoTask(ownerKey: "local", title: "Read"),
            operationID: "task", scope: scope, now: 1, today: 10)
        var candidate = draft()
        candidate.taskIDs = [task.id]
        candidate.taskSelections = [NivoTodoSelection(taskId: task.id, expectedRevision: task.revision,
            requestedStatus: .done, completedDay: 8)]
        let saved = try await repository.saveMosaic(candidate, operationID: "save", scope: scope, now: 2, today: 10)
        XCTAssertEqual(saved.entry?.day, 10)
        XCTAssertEqual(saved.tasks.first?.completedDay, 8)
    }

    /// 已删除关联仍可保留历史，但用户移除后不会被原记录自动加回来。
    func testDeletedTaskLinkCanBeKeptOrRemoved() async throws {
        let repository = try repository()
        let scope = try await repository.open(ownerKey: "local", clock: clock)
        let task = try await repository.saveTask(NivoTodoTask(ownerKey: "local", title: "Read"),
            operationID: "task", scope: scope, now: 1, today: 10)
        var candidate = draft()
        candidate.taskIDs = [task.id]
        let saved = try await repository.saveMosaic(candidate, operationID: "save", scope: scope, now: 2, today: 10)
        _ = try await repository.deleteTask(id: task.id, expectedRevision: task.revision,
            operationID: "delete-task", scope: scope, now: 3)
        let edit = try NivoMosaicRules.draft(from: XCTUnwrap(saved.entry), now: 4)
        let kept = try await repository.saveMosaic(edit, operationID: "keep-link", scope: scope, now: 4, today: 10)
        XCTAssertEqual(kept.entry?.taskSnapshots, saved.entry?.taskSnapshots)
        var remove = try NivoMosaicRules.draft(from: XCTUnwrap(kept.entry), now: 5)
        remove.taskIDs = []
        let removed = try await repository.saveMosaic(remove, operationID: "remove-link", scope: scope, now: 5, today: 10)
        XCTAssertEqual(removed.entry?.taskSnapshots, [])
    }

    /// 旧草稿未写勾选意图时，改正文不能撤销原有打卡。
    func testLegacyDraftWithoutHabitIntentPreservesDoneMark() async throws {
        let repository = try repository()
        let scope = try await repository.open(ownerKey: "local", clock: clock)
        let habit = try await saveHabit(repository, scope: scope)
        var candidate = draft()
        candidate.habitID = habit.id
        candidate.shouldMarkHabitDone = true
        let saved = try await repository.saveMosaic(candidate, operationID: "save", scope: scope, now: 2, today: 10)
        var edit = try NivoMosaicRules.draft(from: XCTUnwrap(saved.entry), now: 3)
        XCTAssertNil(edit.shouldMarkHabitDone)
        edit.text = "Updated description only."
        _ = try await repository.saveMosaic(edit, operationID: "edit", scope: scope, now: 3, today: 10)
        let state = try await repository.mosaicSnapshot(scope: scope)
        XCTAssertEqual(state.habitDays?.first?.status, .done)
    }

    /// 用真实计时事务创建来源，实际时长由时钟区间结算，不直接伪造持久模型。
    private func finishedReflectionFocus(_ repository: NivoLifeRepository, scope: NivoLifeScope,
                                         taskID: String? = nil, mode: NivoFocusMode = .stopwatch,
                                         elapsed: Int64 = 5_000,
                                         startedAt: Int64 = 1_000_000) async throws -> NivoFocusSession {
        let start = try await repository.startFocus(title: "Read", taskID: taskID, mode: mode, minutes: 1,
            operationID: UUID().uuidString, scope: scope,
            clock: NivoFocusClockSample(wallMs: startedAt, elapsedMs: 1_000, bootID: "test"))
        return try await repository.controlFocus(action: "finish", id: start.id, expectedRevision: start.revision,
            operationID: UUID().uuidString, scope: scope,
            clock: NivoFocusClockSample(wallMs: startedAt + elapsed, elapsedMs: 1_000 + elapsed, bootID: "test"))
    }

    /// 首次保存捕获真实起止及关联时间，来源删除后改正文也保留同一历史快照。
    func testReflectionLinkTimesSurviveEditingAfterSourcesAreDeleted() async throws {
        let repository = try repository()
        let scope = try await repository.open(ownerKey: "local", clock: clock)
        let task = try await repository.saveTask(NivoTodoTask(ownerKey: "local", title: "Read"),
            operationID: "task", scope: scope, now: 1, today: 10)
        let focus = try await finishedReflectionFocus(repository, scope: scope, taskID: task.id,
            startedAt: 86_399_000)
        var opened = try await repository.openFocusReflection(sessionID: focus.id, scope: scope,
            now: 90_000_000, timeZone: XCTUnwrap(TimeZone(secondsFromGMT: 0)))
        opened.text = "Observed after midnight."
        let saved = try await repository.saveMosaic(opened, operationID: "save-times", scope: scope,
            now: 90_001_000, today: 10)
        let original = try XCTUnwrap(saved.entry)
        XCTAssertEqual(original.taskSnapshots?.first?.linkedAt, 90_001_000)
        XCTAssertEqual(original.focusSnapshots?.first?.startedAt, 86_399_000)
        XCTAssertEqual(original.focusSnapshots?.first?.endedAt, 86_404_000)
        XCTAssertEqual(original.focusSnapshots?.first?.elapsedMs, 5_000)
        let decoded = try JSONDecoder().decode(NivoMosaicEntry.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded, original)
        _ = try await repository.deleteTask(id: task.id, expectedRevision: task.revision,
            operationID: "delete-task", scope: scope, now: 90_002_000)
        _ = try await repository.controlFocus(action: "delete", id: focus.id, expectedRevision: focus.revision,
            operationID: "delete-focus", scope: scope, clock: clock)
        var edit = NivoMosaicRules.draft(from: original, now: 90_003_000)
        edit.text = "Corrected description after deleting the sources."
        edit.day = 2
        let result = try await repository.saveMosaic(edit, operationID: "edit-times", scope: scope,
            now: 90_003_000, today: 10)
        let edited = try XCTUnwrap(result.entry)
        XCTAssertEqual(edited.taskIDs, original.taskIDs)
        XCTAssertEqual(edited.taskSnapshots, original.taskSnapshots)
        XCTAssertEqual(edited.focusSnapshots, original.focusSnapshots)
        XCTAssertEqual(edited.updatedAt, 90_003_000)
        XCTAssertEqual(edited.day, 2)
    }

    /// 旧文件缺失时间仍可解码；即使来源尚在，编辑时也不回填一个新的历史事实。
    func testLegacyLinkTimesStayUnknownWhenEditingWithLiveSources() async throws {
        let repository = try repository()
        let scope = try await repository.open(ownerKey: "local", clock: clock)
        let task = try await repository.saveTask(NivoTodoTask(ownerKey: "local", title: "Read"),
            operationID: "task", scope: scope, now: 1, today: 10)
        let focus = try await finishedReflectionFocus(repository, scope: scope, taskID: task.id)
        var candidate = draft()
        candidate.taskIDs = [task.id]
        candidate.focusIDs = [focus.id]
        let saved = try await repository.saveMosaic(candidate, operationID: "save", scope: scope, now: 2, today: 10)
        var legacyEntry = try XCTUnwrap(saved.entry)
        legacyEntry.taskSnapshots = [.init(id: task.id, title: "Historical task", status: .todo)]
        legacyEntry.focusSnapshots = [.init(id: focus.id, title: "Historical focus", elapsedMs: focus.elapsedMs)]
        let encoded = try JSONEncoder().encode(legacyEntry)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let taskPayload = try XCTUnwrap((payload["taskSnapshots"] as? [[String: Any]])?.first)
        let focusPayload = try XCTUnwrap((payload["focusSnapshots"] as? [[String: Any]])?.first)
        XCTAssertNil(taskPayload["linkedAt"])
        XCTAssertNil(focusPayload["startedAt"])
        XCTAssertNil(focusPayload["endedAt"])
        let decoded = try JSONDecoder().decode(NivoMosaicEntry.self, from: encoded)
        let token = UUID()
        var backup = try await repository.beginBackup(scope: scope, token: token, clock: clock)
        backup.mosaic?.entries = [decoded]
        try await repository.installBackup(backup, token: token)
        await repository.endBackup(token: token)
        let restoredScope = try await repository.open(ownerKey: "local", clock: clock)
        var edit = NivoMosaicRules.draft(from: decoded, now: 3)
        edit.text = "Corrected legacy description."
        let result = try await repository.saveMosaic(edit, operationID: "edit-legacy", scope: restoredScope, now: 3, today: 10)
        XCTAssertEqual(result.entry?.taskSnapshots, decoded.taskSnapshots)
        XCTAssertEqual(result.entry?.focusSnapshots, decoded.focusSnapshots)
        XCTAssertNil(result.entry?.taskSnapshots?.first?.linkedAt)
        XCTAssertNil(result.entry?.focusSnapshots?.first?.startedAt)
        XCTAssertNil(result.entry?.focusSnapshots?.first?.endedAt)
        var explicit = try NivoMosaicRules.draft(from: XCTUnwrap(result.entry), now: 4)
        explicit.taskSelections = [.init(taskId: task.id, expectedRevision: task.revision, requestedStatus: .done)]
        let refreshed = try await repository.saveMosaic(explicit, operationID: "refresh-legacy-status",
            scope: restoredScope, now: 4, today: 10)
        XCTAssertEqual(refreshed.entry?.taskSnapshots?.first?.status, .done)
        XCTAssertNil(refreshed.entry?.taskSnapshots?.first?.linkedAt)
    }

    /// 日期取结束时的自然日，且不会覆盖当天自由草稿。
    func testReflectionUsesEndedDayAndKeepsIndependentFreeDraft() async throws {
        let repository = try repository()
        let scope = try await repository.open(ownerKey: "local", clock: clock)
        let free = draft()
        _ = try await repository.saveMosaicDraft(free, scope: scope)
        let task = try await repository.saveTask(NivoTodoTask(ownerKey: "local", title: "Read"),
            operationID: "task", scope: scope, now: 1, today: 10)
        let session = try await finishedReflectionFocus(repository, scope: scope, taskID: task.id, startedAt: 86_399_000)
        let opened = try await repository.openFocusReflection(sessionID: session.id, scope: scope, now: 90_000_000,
            timeZone: XCTUnwrap(TimeZone(secondsFromGMT: 0)))
        XCTAssertEqual(opened.day, 1)
        XCTAssertEqual(opened.focusIDs, [session.id])
        XCTAssertEqual(opened.taskIDs, [task.id])
        XCTAssertNil(opened.taskSelections?.first?.requestedStatus)
        XCTAssertEqual(opened.reflectionSessionID, session.id)
        let state = try await repository.snapshot(scope: scope, clock: clock)
        XCTAssertEqual(state.mosaic?.drafts.first { $0.id == free.id }, free)
        XCTAssertEqual(state.tasks, [task])
        XCTAssertEqual(state.mosaic?.drafts.count, 2)
    }

    /// 无效来源在仓库边界拒绝，按钮资格与实际打开规则一致。
    func testReflectionRejectsRunningBreakZeroAndDeletedSessions() async throws {
        let repository = try repository()
        let scope = try await repository.open(ownerKey: "local", clock: clock)
        let running = try await repository.startFocus(title: "Read", mode: .stopwatch, minutes: 1,
            operationID: "running", scope: scope, clock: clock)
        XCTAssertFalse(NivoFocusReflectionRules.canReflect(running))
        do {
            _ = try await repository.openFocusReflection(sessionID: running.id, scope: scope, now: 2)
            XCTFail("未结束会话不能生成心得")
        } catch { XCTAssertEqual(error as? NivoLifeError, .notFound("focus_reflection")) }
        let zero = try await repository.controlFocus(action: "finish", id: running.id,
            expectedRevision: running.revision, operationID: "zero", scope: scope, clock: clock)
        let rest = try await finishedReflectionFocus(repository, scope: scope, mode: .rest)
        let finished = try await finishedReflectionFocus(repository, scope: scope)
        let deleted = try await repository.controlFocus(action: "delete", id: finished.id,
            expectedRevision: finished.revision, operationID: "delete", scope: scope, clock: clock)
        for session in [zero, rest, deleted] {
            XCTAssertFalse(NivoFocusReflectionRules.canReflect(session))
            do {
                _ = try await repository.openFocusReflection(sessionID: session.id, scope: scope, now: 3)
                XCTFail("休息、零时长和删除记录不能生成心得")
            } catch { XCTAssertEqual(error as? NivoLifeError, .notFound("focus_reflection")) }
        }
        let state = try await repository.mosaicSnapshot(scope: scope)
        XCTAssertTrue(state.drafts.isEmpty)
    }

    /// 重新进入不会重置正文、改期、心情或重新勾选已取消的关联。
    func testReflectionRestoresEditedDraftWithoutReaddingLinks() async throws {
        let repository = try repository()
        let scope = try await repository.open(ownerKey: "local", clock: clock)
        let session = try await finishedReflectionFocus(repository, scope: scope)
        var opened = try await repository.openFocusReflection(sessionID: session.id, scope: scope, now: 2)
        opened.text = "I noticed a useful pattern."
        opened.day = 3
        opened.mood = .good
        opened.shape = "circle"
        opened.focusIDs = []
        opened.updatedAt = 4
        _ = try await repository.saveMosaicDraft(opened, scope: scope)
        try await repository.close(clock: clock)
        let reopenedScope = try await repository.open(ownerKey: "local", clock: clock)
        let restored = try await repository.openFocusReflection(sessionID: session.id, scope: reopenedScope, now: 6)
        XCTAssertEqual(restored, opened)
        let state = try await repository.mosaicSnapshot(scope: reopenedScope)
        XCTAssertEqual(state.drafts, [opened])
    }

    /// 同一来源不同提交标识也只生成一条记录，保存后迟到自动保存不得复活原草稿。
    func testReflectionSaveDeduplicatesAndReopensPublishedEntry() async throws {
        let repository = try repository()
        let scope = try await repository.open(ownerKey: "local", clock: clock)
        let session = try await finishedReflectionFocus(repository, scope: scope)
        var opened = try await repository.openFocusReflection(sessionID: session.id, scope: scope, now: 2)
        opened.text = "Keep this reflection even after removing its visible focus link."
        opened.focusIDs = []
        let saved = try await repository.saveMosaic(opened, operationID: "publish", scope: scope, now: 3, today: 10)
        let repeated = try await repository.saveMosaic(opened, operationID: "publish-again", scope: scope, now: 4, today: 10)
        XCTAssertEqual(repeated.entry, saved.entry)
        opened.updatedAt = 99
        do {
            _ = try await repository.saveMosaicDraft(opened, scope: scope)
            XCTFail("已经保存的来源不能被迟到自动保存重新创建")
        } catch { XCTAssertEqual(error as? NivoLifeError, .invalidTransition("reflection_saved")) }
        try await repository.close(clock: clock)
        let reloadedScope = try await repository.open(ownerKey: "local", clock: clock)
        let edit = try await repository.openFocusReflection(sessionID: session.id, scope: reloadedScope, now: 5)
        XCTAssertEqual(edit.entryID, saved.entry?.id)
        XCTAssertEqual(edit.text, opened.text)
        XCTAssertEqual(edit.focusIDs, [])
        XCTAssertEqual(edit.reflectionSessionID, session.id)
        let state = try await repository.mosaicSnapshot(scope: reloadedScope)
        XCTAssertEqual(state.entries.count, 1)
        XCTAssertTrue(state.drafts.isEmpty)
    }

    /// 遗留草稿与已发布来源共存时保留双方，重新打开和提交都不能静默抹掉正文。
    func testChangedReflectionRetryConflictsAndKeepsPersistedDraftAndEntry() async throws {
        let repository = try repository()
        let scope = try await repository.open(ownerKey: "local", clock: clock)
        let session = try await finishedReflectionFocus(repository, scope: scope)
        var original = try await repository.openFocusReflection(sessionID: session.id, scope: scope, now: 2)
        original.text = "Published observation."
        let saved = try await repository.saveMosaic(original, operationID: "publish", scope: scope, now: 3, today: 10)
        var leftover = original
        leftover.text = "Unpublished observation from an older backup."
        leftover.updatedAt = 4
        // 安装旧版本可能已经接受的共存快照，验证仓库也保护遗留正文。
        let token = UUID()
        var legacy = try await repository.beginBackup(scope: scope, token: token, clock: clock)
        legacy.mosaic?.drafts.append(leftover)
        try await repository.installBackup(legacy, token: token)
        await repository.endBackup(token: token)
        let restoredScope = try await repository.open(ownerKey: "local", clock: clock)
        var edited = leftover
        edited.text += " Newly edited text."
        let before = try await repository.snapshot(scope: restoredScope, clock: clock)
        do {
            _ = try await repository.saveMosaic(edited, operationID: "changed-retry", scope: restoredScope, now: 5, today: 10)
            XCTFail("不同正文不能伪装成重复保存成功")
        } catch { XCTAssertEqual(error as? NivoLifeError, .operationConflict) }
        do {
            _ = try await repository.openFocusReflection(sessionID: session.id, scope: restoredScope, now: 6)
            XCTFail("重新打开也不能删除遗留草稿")
        } catch { XCTAssertEqual(error as? NivoLifeError, .operationConflict) }
        let after = try await repository.snapshot(scope: restoredScope, clock: clock)
        XCTAssertEqual(after, before)
        XCTAssertEqual(after.mosaic?.entries, [try XCTUnwrap(saved.entry)])
        XCTAssertEqual(after.mosaic?.drafts, [leftover])
        XCTAssertEqual(edited.text, leftover.text + " Newly edited text.")
        XCTAssertNil(after.operations["changed-retry"])
    }

    /// 每个可编辑内容字段都参与重复请求比较，不只检查正文或来源标识。
    func testReflectionRetryChecksMeaningfulContentAndIgnoresRequestMetadata() async throws {
        let repository = try repository()
        let scope = try await repository.open(ownerKey: "local", clock: clock)
        let session = try await finishedReflectionFocus(repository, scope: scope)
        var original = try await repository.openFocusReflection(sessionID: session.id, scope: scope, now: 2)
        original.text = "A useful observation."
        let saved = try await repository.saveMosaic(original, operationID: "publish", scope: scope, now: 3, today: 10)
        var retry = original
        retry.updatedAt = 999
        retry.text = "  A useful observation.\n"
        retry.shape = nil
        let repeated = try await repository.saveMosaic(retry, operationID: "same-content", scope: scope, now: 4, today: 10)
        XCTAssertEqual(repeated.entry, saved.entry)
        let changes: [(inout NivoMosaicDraft) -> Void] = [
            { $0.text = "A different observation." },
            { $0.day += 1 },
            { $0.mood = .good },
            { $0.taskIDs = ["different-task"] },
            { $0.focusIDs = [] },
            { $0.mediaPath = "00000000-0000-4000-8000-000000000000.jpg" },
            { $0.crop = NivoMosaicCrop(focusX: 0.3, focusY: 0.4, zoom: 2) },
            { $0.shape = "circle" },
            { $0.habitID = "different-habit"; $0.shouldMarkHabitDone = true }
        ]
        let before = try await repository.snapshot(scope: scope, clock: clock)
        for (index, change) in changes.enumerated() {
            var changed = original
            change(&changed)
            do {
                _ = try await repository.saveMosaic(changed, operationID: "changed-\(index)", scope: scope, now: 5, today: 10)
                XCTFail("内容字段变化必须保留输入并报告冲突：\(index)")
            } catch { XCTAssertEqual(error as? NivoLifeError, .operationConflict) }
        }
        let after = try await repository.snapshot(scope: scope, clock: clock)
        XCTAssertEqual(after, before)
    }

    /// 仅关联专注也可发布，空正文不会使保存后的来源退回新草稿。
    func testFocusOnlyReflectionSavesOnceAndReopensWithoutText() async throws {
        let repository = try repository()
        let scope = try await repository.open(ownerKey: "local", clock: clock)
        let session = try await finishedReflectionFocus(repository, scope: scope)
        let opened = try await repository.openFocusReflection(sessionID: session.id, scope: scope, now: 2)
        XCTAssertTrue(opened.text.isEmpty)
        XCTAssertTrue(NivoMosaicRules.canSave(opened))
        let first = try await repository.saveMosaic(opened, operationID: "publish", scope: scope, now: 3, today: 10)
        let second = try await repository.saveMosaic(opened, operationID: "again", scope: scope, now: 4, today: 10)
        XCTAssertEqual(first.entry, second.entry)
        let reopened = try await repository.openFocusReflection(sessionID: session.id, scope: scope, now: 5)
        XCTAssertEqual(reopened.entryID, first.entry?.id)
        XCTAssertEqual(reopened.focusIDs, [session.id])
        XCTAssertTrue(reopened.text.isEmpty)
        let state = try await repository.mosaicSnapshot(scope: scope)
        XCTAssertEqual(state.entries.count, 1)
        XCTAssertTrue(state.drafts.isEmpty)
    }

    /// 自然倒计时先由仓库结算，再用已计量的结果关联心得。
    func testNaturallyFinishedFocusCanOpenReflection() async throws {
        let repository = try repository()
        let scope = try await repository.open(ownerKey: "local", clock: clock)
        let started = try await repository.startFocus(title: "Read", mode: .pomodoro, minutes: 1,
            operationID: "start", scope: scope, clock: clock)
        let state = try await repository.snapshot(scope: scope,
            clock: NivoFocusClockSample(wallMs: clock.wallMs + 70_000, elapsedMs: clock.elapsedMs + 70_000, bootID: "test"))
        let finished = try XCTUnwrap(state.focusSessions.first)
        XCTAssertEqual(finished.elapsedMs, 60_000)
        XCTAssertEqual(finished.endedAt, clock.wallMs + 60_000)
        XCTAssertTrue(NivoFocusReflectionRules.canReflect(finished))
        let opened = try await repository.openFocusReflection(sessionID: started.id, scope: scope, now: clock.wallMs + 70_000)
        XCTAssertEqual(opened.focusIDs, [finished.id])
    }

    /// 新心得只做关联，连草稿中携带的显式完成意图也不能写入待办状态。
    func testReflectionCannotCompleteLinkedTask() async throws {
        let repository = try repository()
        let scope = try await repository.open(ownerKey: "local", clock: clock)
        let task = try await repository.saveTask(NivoTodoTask(ownerKey: "local", title: "Read"),
            operationID: "task", scope: scope, now: 1, today: 10)
        let session = try await finishedReflectionFocus(repository, scope: scope, taskID: task.id)
        var opened = try await repository.openFocusReflection(sessionID: session.id, scope: scope, now: 2)
        opened.taskSelections = [NivoTodoSelection(taskId: task.id, expectedRevision: task.revision, requestedStatus: .done)]
        let saved = try await repository.saveMosaic(opened, operationID: "publish", scope: scope, now: 3, today: 10)
        let state = try await repository.snapshot(scope: scope, clock: clock)
        XCTAssertEqual(state.tasks, [task])
        XCTAssertEqual(saved.entry?.taskSnapshots?.first?.status, .todo)
    }

    /// 恢复草稿使用任务当前状态，不因旧版本或旧状态意图把已完成待办回退。
    func testReflectionKeepsLatestTaskStatusAfterStaleDraft() async throws {
        let repository = try repository()
        let scope = try await repository.open(ownerKey: "local", clock: clock)
        let task = try await repository.saveTask(NivoTodoTask(ownerKey: "local", title: "Read"),
            operationID: "task", scope: scope, now: 1, today: 10)
        let session = try await finishedReflectionFocus(repository, scope: scope, taskID: task.id)
        var opened = try await repository.openFocusReflection(sessionID: session.id, scope: scope, now: 2)
        let completed = try await repository.changeTaskStatus(id: task.id, status: .done, expectedRevision: task.revision,
            operationID: "complete", scope: scope, now: 3, today: 10)
        opened.taskSelections = [NivoTodoSelection(taskId: task.id, expectedRevision: task.revision, requestedStatus: .inProgress)]
        let saved = try await repository.saveMosaic(opened, operationID: "publish", scope: scope, now: 4, today: 10)
        let state = try await repository.snapshot(scope: scope, clock: clock)
        XCTAssertEqual(state.tasks, [completed])
        XCTAssertEqual(saved.entry?.taskSnapshots?.first?.status, .done)
    }

    /// 任务在打开前或编辑期间被删除，都可保存心得且不恢复删除记录。
    func testReflectionSkipsDeletedTaskBeforeOpenAndBeforeSave() async throws {
        let repository = try repository()
        let scope = try await repository.open(ownerKey: "local", clock: clock)
        let task = try await repository.saveTask(NivoTodoTask(ownerKey: "local", title: "Read"),
            operationID: "task", scope: scope, now: 1, today: 10)
        let first = try await finishedReflectionFocus(repository, scope: scope, taskID: task.id)
        let second = try await finishedReflectionFocus(repository, scope: scope, taskID: task.id)
        let opened = try await repository.openFocusReflection(sessionID: first.id, scope: scope, now: 2)
        _ = try await repository.deleteTask(id: task.id, expectedRevision: task.revision,
            operationID: "delete", scope: scope, now: 3)
        let later = try await repository.openFocusReflection(sessionID: second.id, scope: scope, now: 4)
        XCTAssertTrue(later.taskIDs.isEmpty)
        let saved = try await repository.saveMosaic(opened, operationID: "publish", scope: scope, now: 5, today: 10)
        XCTAssertEqual(saved.entry?.taskIDs, [])
        XCTAssertEqual(saved.entry?.focusIDs, [first.id])
        let state = try await repository.snapshot(scope: scope, clock: clock)
        XCTAssertNotNil(state.tasks.first?.deletedAt)
    }

    /// 同账号切出切回也改变代次，旧页面不能恢复、保存或自动保存心得。
    func testReflectionRejectsStaleAccountGeneration() async throws {
        let repository = try repository()
        let scope = try await repository.open(ownerKey: "local", clock: clock)
        let session = try await finishedReflectionFocus(repository, scope: scope)
        let opened = try await repository.openFocusReflection(sessionID: session.id, scope: scope, now: 2)
        _ = try await repository.open(ownerKey: "other", clock: clock)
        let current = try await repository.open(ownerKey: "local", clock: clock)
        XCTAssertNotEqual(scope, current)
        do {
            _ = try await repository.openFocusReflection(sessionID: session.id, scope: scope, now: 3)
            XCTFail("旧代次不能打开心得")
        } catch { XCTAssertEqual(error as? NivoLifeError, .accountChanged) }
        do {
            _ = try await repository.saveMosaic(opened, operationID: "old-save", scope: scope, now: 3, today: 10)
            XCTFail("旧代次不能提交心得")
        } catch { XCTAssertEqual(error as? NivoLifeError, .accountChanged) }
        do {
            _ = try await repository.saveMosaicDraft(opened, scope: scope)
            XCTFail("旧代次不能自动保存心得")
        } catch { XCTAssertEqual(error as? NivoLifeError, .accountChanged) }
        let restored = try await repository.openFocusReflection(sessionID: session.id, scope: current, now: 4)
        XCTAssertEqual(restored, opened)
    }

    /// 备份恢复撤销旧凭证；新代次从持久来源恢复同一心得，而非从旧页面重放。
    func testReflectionBackupRestoreKeepsIdentityAndRevokesOldScope() async throws {
        let repository = try repository()
        let scope = try await repository.open(ownerKey: "local", clock: clock)
        let session = try await finishedReflectionFocus(repository, scope: scope)
        let opened = try await repository.openFocusReflection(sessionID: session.id, scope: scope, now: 2)
        let token = UUID()
        let backup = try await repository.beginBackup(scope: scope, token: token, clock: clock)
        try await repository.installBackup(backup, token: token)
        await repository.endBackup(token: token)
        let current = try await repository.open(ownerKey: "local", clock: clock)
        do {
            _ = try await repository.openFocusReflection(sessionID: session.id, scope: scope, now: 3)
            XCTFail("恢复前的排队点击必须失效")
        } catch { XCTAssertEqual(error as? NivoLifeError, .accountChanged) }
        let restored = try await repository.openFocusReflection(sessionID: session.id, scope: current, now: 4)
        XCTAssertEqual(restored, opened)
        let rebound = try NivoPersonalBackupMerge.life(local: NivoLifeState(ownerKey: "other"), incoming: backup, owner: "other")
        XCTAssertEqual(rebound.mosaic?.drafts.first?.id, opened.id)
        XCTAssertEqual(rebound.mosaic?.drafts.first?.ownerKey, "other")
    }

    /// 回收站仍占有来源身份，再次点击不能绕过删除状态生成第二条记录。
    func testReflectionDoesNotDuplicateDeletedPublishedEntry() async throws {
        let repository = try repository()
        let scope = try await repository.open(ownerKey: "local", clock: clock)
        let session = try await finishedReflectionFocus(repository, scope: scope)
        let opened = try await repository.openFocusReflection(sessionID: session.id, scope: scope, now: 2)
        let saved = try await repository.saveMosaic(opened, operationID: "publish", scope: scope, now: 3, today: 10)
        let entry = try XCTUnwrap(saved.entry)
        _ = try await repository.changeMosaicEntry(id: entry.id, expectedRevision: entry.revision ?? 1,
            action: "delete_fragment", operationID: "delete", scope: scope, now: 4)
        do {
            _ = try await repository.openFocusReflection(sessionID: session.id, scope: scope, now: 5)
            XCTFail("回收站记录不能被重复点击绕过")
        } catch { XCTAssertEqual(error as? NivoLifeError, .notFound("focus_reflection")) }
        let state = try await repository.mosaicSnapshot(scope: scope)
        XCTAssertEqual(state.entries.count, 1)
        XCTAssertTrue(state.drafts.isEmpty)
    }

    /// 恢复输入不能把心得来源换绑给另一条记录，旧普通草稿仍正常解码。
    func testReflectionSourceValidationAndLegacyDraftCompatibility() async throws {
        let repository = try repository()
        let scope = try await repository.open(ownerKey: "local", clock: clock)
        let session = try await finishedReflectionFocus(repository, scope: scope)
        let opened = try await repository.openFocusReflection(sessionID: session.id, scope: scope, now: 2)
        var invalid = opened
        invalid.reflectionSessionID = "other-session"
        XCTAssertThrowsError(try NivoMosaicRules.validateDraft(invalid, owner: "local"))
        let legacy = draft()
        let decoded = try JSONDecoder().decode(NivoMosaicDraft.self, from: JSONEncoder().encode(legacy))
        XCTAssertEqual(decoded, legacy)
        XCTAssertNil(decoded.reflectionSessionID)
    }

    private func saveHabit(_ repository: NivoLifeRepository, scope: NivoLifeScope) async throws -> NivoMosaicHabit {
        try await repository.saveMosaicHabit(NivoMosaicHabit(ownerKey: "local", id: "", title: "Read", weekdays: Set(1...7), createdAt: 0),
            operationID: "habit", scope: scope, today: 10, now: 1)
    }

    func testForeignOwnerFutureDateAndTraversalAreRejected() async throws {
        let repository = try repository()
        let scope = try await repository.open(ownerKey: "local", clock: clock)
        do {
            _ = try await repository.saveMosaicDraft(draft(owner: "other"), scope: scope)
            XCTFail("跨账户草稿必须拒绝")
        } catch { XCTAssertEqual(error as? NivoLifeError, .accountChanged) }
        do {
            _ = try await repository.saveMosaic(draft(), operationID: "future", scope: scope, now: 3, today: 9)
            XCTFail("未来日期不能保存为现实记录")
        } catch { XCTAssertEqual(error as? NivoLifeError, .invalidField("future_fragment")) }
        XCTAssertThrowsError(try NivoMosaicRules.validateMediaPath("../secret.jpg"))
        XCTAssertThrowsError(try NivoMosaicRules.validateMediaPath("/tmp/file.jpg"))
        let state = try await repository.snapshot(scope: scope, clock: clock)
        XCTAssertTrue(state.operations.isEmpty)
    }

    func testDiskFailureDoesNotPublishMosaicOrOperation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nivo-mosaic-fail-" + UUID().uuidString)
        addTeardownBlock { if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) } }
        let repository = NivoLifeRepository(directory: root, writer: { _, _ in throw CocoaError(.fileWriteOutOfSpace) })
        let scope = try await repository.open(ownerKey: "local", clock: clock)
        do {
            _ = try await repository.saveMosaic(draft(), operationID: "save", scope: scope, now: 1, today: 10)
            XCTFail("磁盘失败不能返回成功")
        } catch { XCTAssertTrue(error is CocoaError) }
        let state = try await repository.snapshot(scope: scope, clock: clock)
        XCTAssertNil(state.mosaic)
        XCTAssertTrue(state.operations.isEmpty)
    }
}
