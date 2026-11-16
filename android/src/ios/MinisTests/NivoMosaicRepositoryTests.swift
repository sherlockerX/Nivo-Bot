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
