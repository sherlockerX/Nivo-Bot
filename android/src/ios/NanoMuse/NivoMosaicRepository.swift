import Foundation

/// 已保存碎片和本次涉及的待办版本作为一个事务回执返回。
struct NivoMosaicSaveResult: Codable, Equatable, Sendable {
    var entry: NivoMosaicEntry?
    var tasks: [NivoTodoTask]
}

/// 每个动作进入幂等签名，防止不同类型操作复用同一个请求标识。
private struct NivoMosaicRequest: Codable {
    var action: String
    var draft: NivoMosaicDraft?
    var id: String?
    var revision: Int64?
    var habit: NivoMosaicHabit?
    var day: Int64?
    var habitStatus: NivoMosaicHabitDay.Status?
    var dayInfo: NivoMosaicDayInfo?
}

extension NivoLifeRepository {
    /// 心得来源、有效待办与独立草稿在同一账户事务内读取，恢复时完整保留用户编辑。
    func openFocusReflection(sessionID: String, scope: NivoLifeScope, now: Int64,
                             timeZone: TimeZone = .current) throws -> NivoMosaicDraft {
        try updateLife(scope: scope) { state in
            guard let session = state.focusSessions.first(where: { $0.id == sessionID && $0.ownerKey == scope.ownerKey }),
                  NivoFocusReflectionRules.canReflect(session), let endedAt = session.endedAt else {
                throw NivoLifeError.notFound("focus_reflection")
            }
            var mosaic = state.mosaic ?? NivoMosaicState(ownerKey: scope.ownerKey)
            let draftID = NivoFocusReflectionRules.draftID(sessionID: sessionID)
            if let entry = mosaic.entries.first(where: { $0.reflectionSessionID == sessionID }) {
                guard entry.deletedAt == nil else { throw NivoLifeError.notFound("focus_reflection") }
                // 已发布条目和遗留草稿同时存在时保留双方，不能静默删除尚未提交的正文。
                guard !mosaic.drafts.contains(where: { $0.id == draftID }) else {
                    throw NivoLifeError.operationConflict
                }
                let edit = mosaic.drafts.first { $0.entryID == entry.id }
                    ?? NivoMosaicRules.draft(from: entry, now: now, habitDays: mosaic.habitDays ?? [])
                state.mosaic = mosaic
                return edit
            }
            if let draft = mosaic.drafts.first(where: { $0.id == draftID }) { return draft }
            let task = state.tasks.first { $0.id == session.taskId && $0.ownerKey == scope.ownerKey && $0.deletedAt == nil }
            let draft = NivoMosaicDraft(ownerKey: scope.ownerKey, id: draftID,
                day: NivoLifeDay.value(Date(timeIntervalSince1970: Double(endedAt) / 1_000), timeZone: timeZone),
                text: "", taskIDs: task.map { [$0.id] } ?? [], focusIDs: [session.id], updatedAt: now,
                taskSelections: task.map { [NivoTodoSelection(taskId: $0.id, expectedRevision: $0.revision)] } ?? [],
                shouldMarkHabitDone: false, shape: "rounded", reflectionSessionID: session.id)
            mosaic.drafts.append(draft)
            state.mosaic = mosaic
            return draft
        }
    }

    /// 自动保存只写草稿；任务状态变更留待用户正式保存。
    func saveMosaicDraft(_ draft: NivoMosaicDraft, scope: NivoLifeScope) throws -> NivoMosaicDraft {
        try updateMosaic(scope: scope) { mosaic in
            try NivoMosaicRules.validateDraft(draft, owner: scope.ownerKey)
            try Self.requireReflectionIdentity(draft, in: mosaic)
            if let source = draft.reflectionSessionID, draft.entryID == nil,
               mosaic.entries.contains(where: { $0.reflectionSessionID == source }) {
                throw NivoLifeError.invalidTransition("reflection_saved")
            }
            if let current = mosaic.drafts.first(where: { $0.id == draft.id }), current.updatedAt > draft.updatedAt {
                return current
            }
            mosaic.drafts.removeAll { $0.id == draft.id }
            mosaic.drafts.append(draft)
            return draft
        }
    }

    /// 正文、待办执行状态、专注关联和习惯标记一次提交，任一步失败均不发布候选状态。
    func saveMosaic(_ input: NivoMosaicDraft, operationID: String, scope: NivoLifeScope,
                    now: Int64, today: Int64) throws -> NivoMosaicSaveResult {
        let request = NivoMosaicRequest(action: "mosaic_save", draft: input)
        return try transaction(operationID: operationID, request: request, scope: scope) { state in
            try NivoMosaicRules.validateDraft(input, owner: scope.ownerKey)
            var mosaic = state.mosaic ?? NivoMosaicState(ownerKey: scope.ownerKey)
            try Self.requireReflectionIdentity(input, in: mosaic)
            if let source = input.reflectionSessionID, input.entryID == nil,
               let saved = mosaic.entries.first(where: { $0.reflectionSessionID == source }) {
                guard saved.deletedAt == nil else { throw NivoLifeError.notFound("focus_reflection") }
                guard NivoFocusReflectionRules.hasSameContent(input, as: saved, habitDays: mosaic.habitDays ?? []) else {
                    throw NivoLifeError.operationConflict
                }
                return NivoMosaicSaveResult(entry: saved, tasks: [])
            }
            let draft = try Self.reflectionLinks(input, in: state)
            try requireMosaicMedia(draft.mediaPath, owner: scope.ownerKey)
            let old = try Self.previousEntry(draft, in: mosaic)
            guard draft.day <= today || old?.day == draft.day else { throw NivoLifeError.invalidField("future_fragment") }
            guard NivoMosaicRules.canSave(draft) else { throw NivoLifeError.invalidField("empty_fragment") }
            let habit = try Self.mosaicHabit(draft.habitID, in: mosaic)
            if !NivoMosaicRules.hasContent(draft), let habit {
                Self.markHabit(habit.id, day: draft.day, status: .done, now: now, in: &mosaic)
                Self.refreshMosaicDay(day: draft.day, mood: draft.mood, now: now, in: &mosaic)
                mosaic.drafts.removeAll { $0.id == draft.id }
                state.mosaic = mosaic
                return NivoMosaicSaveResult(entry: nil, tasks: [])
            }
            let tasks = try Self.applyMosaicTasks(draft, old: old, state: &state, now: now, today: today)
            let focus = try Self.mosaicFocus(draft.focusIDs, old: old, in: state)
            let entry = NivoMosaicEntry(
                ownerKey: scope.ownerKey, id: old?.id ?? UUID().uuidString, day: draft.day,
                text: draft.text.trimmingCharacters(in: .whitespacesAndNewlines), mood: draft.mood,
                taskIDs: draft.taskIDs, focusIDs: draft.focusIDs, mediaPath: draft.mediaPath,
                createdAt: old?.createdAt ?? now, updatedAt: now, deletedAt: nil,
                revision: (old?.revision ?? (old == nil ? 0 : 1)) + 1,
                habitID: habit?.id, habitTitle: habit?.title,
                taskSnapshots: tasks.links,
                focusSnapshots: focus, crop: draft.crop, shape: draft.shape ?? "rounded",
                zoneID: old?.zoneID ?? TimeZone.current.identifier, reflectionSessionID: draft.reflectionSessionID,
                reflectionTaskSelections: draft.reflectionSessionID == nil ? nil : NivoFocusReflectionRules.taskIntents(draft))
            mosaic.entries.removeAll { $0.id == entry.id }
            mosaic.entries.append(entry)
            mosaic.drafts.removeAll { $0.id == draft.id }
            Self.applyHabitMark(draft, old: old, now: now, in: &mosaic)
            Self.refreshMosaicDay(day: draft.day, mood: draft.mood, now: now, in: &mosaic)
            if let old, old.day != draft.day { Self.refreshMosaicDay(day: old.day, mood: nil, now: now, in: &mosaic) }
            state.mosaic = mosaic
            return NivoMosaicSaveResult(entry: entry, tasks: tasks.tasks)
        }
    }

    /// 回收站只改变记录状态，删除或恢复日记均不倒退已提交的任务进度。
    func changeMosaicEntry(id: String, expectedRevision: Int64, action: String, operationID: String,
                           scope: NivoLifeScope, now: Int64) throws -> NivoMosaicEntry {
        let request = NivoMosaicRequest(action: action, id: id, revision: expectedRevision)
        return try transaction(operationID: operationID, request: request, scope: scope) { state in
            guard ["delete_fragment", "restore_fragment"].contains(action), var mosaic = state.mosaic,
                  let index = mosaic.entries.firstIndex(where: { $0.id == id }) else { throw NivoLifeError.notFound(id) }
            var entry = mosaic.entries[index]
            try NivoTodoRules.requireRevision(expectedRevision, actual: entry.revision ?? 1)
            guard expectedRevision < Int64.max else { throw NivoLifeError.invalidField("revision") }
            entry.deletedAt = action == "delete_fragment" ? now : nil
            entry.updatedAt = now
            entry.revision = expectedRevision + 1
            mosaic.entries[index] = entry
            Self.refreshMosaicDay(day: entry.day, mood: nil, now: now, in: &mosaic)
            state.mosaic = mosaic
            return entry
        }
    }

    /// 删除未发布草稿不会触发完成任务或清除已发布记录。
    func discardMosaicDraft(id: String, operationID: String, scope: NivoLifeScope) throws -> Bool {
        try transaction(operationID: operationID, request: NivoMosaicRequest(action: "discard_draft", id: id), scope: scope) { state in
            var mosaic = state.mosaic ?? NivoMosaicState(ownerKey: scope.ownerKey)
            mosaic.drafts.removeAll { $0.id == id }
            state.mosaic = mosaic
            return true
        }
    }

    /// 回收站保留七天，到期才移除条目，媒体清理由引用扫描另行处理。
    func sweepMosaic(scope: NivoLifeScope, now: Int64) throws {
        let current = try mosaicSnapshot(scope: scope)
        guard current.entries.contains(where: { ($0.deletedAt ?? Int64.max) <= now - NivoMosaicRules.binLifetimeMs }) else { return }
        try updateMosaic(scope: scope) { mosaic in
            mosaic.entries.removeAll { ($0.deletedAt ?? Int64.max) <= now - NivoMosaicRules.binLifetimeMs }
        }
    }

    /// 保存习惯会检查旧版本，日程更改从今天生效。
    func saveMosaicHabit(_ input: NivoMosaicHabit, operationID: String, scope: NivoLifeScope,
                         today: Int64, now: Int64) throws -> NivoMosaicHabit {
        let request = NivoMosaicRequest(action: "save_habit", habit: input, day: today)
        return try transaction(operationID: operationID, request: request, scope: scope) { state in
            var mosaic = state.mosaic ?? NivoMosaicState(ownerKey: scope.ownerKey)
            let previous = mosaic.habits.first { $0.id == input.id }
            guard input.ownerKey == scope.ownerKey else { throw NivoLifeError.accountChanged }
            guard input.id.isEmpty || previous != nil else { throw NivoLifeError.notFound(input.id) }
            if let previous { try NivoTodoRules.requireRevision(input.revision ?? 1, actual: previous.revision ?? 1) }
            var habit = input
            habit.id = previous?.id ?? UUID().uuidString
            habit.title = input.title.trimmingCharacters(in: .whitespacesAndNewlines)
            habit.createdAt = previous?.createdAt ?? now
            let oldRevision = previous?.revision ?? (previous == nil ? 0 : 1)
            guard oldRevision < Int64.max else { throw NivoLifeError.invalidField("revision") }
            habit.revision = oldRevision + 1
            var schedules = previous?.schedules ?? previous.map {
                [NivoMosaicHabitSchedule(fromDay: NivoLifeDay.value(Date(timeIntervalSince1970: Double($0.createdAt) / 1_000)), weekdays: $0.weekdays)]
            } ?? []
            if previous == nil || previous.map({ NivoMosaicRules.weekdays($0, on: today) != input.weekdays }) == true {
                schedules.removeAll { $0.fromDay == today }
                schedules.append(NivoMosaicHabitSchedule(fromDay: today, weekdays: input.weekdays))
            }
            habit.schedules = schedules.sorted { $0.fromDay < $1.fromDay }
            mosaic.habits.removeAll { $0.id == habit.id }
            mosaic.habits.append(habit)
            try NivoMosaicRules.validate(mosaic, owner: scope.ownerKey)
            state.mosaic = mosaic
            return habit
        }
    }

    /// 完成、跳过与清除均属于用户操作，不把习惯勾选当成日记条目。
    func setMosaicHabitDay(habitID: String, day: Int64, status: NivoMosaicHabitDay.Status?, operationID: String,
                          scope: NivoLifeScope, today: Int64, now: Int64) throws -> Bool {
        let request = NivoMosaicRequest(action: "habit_day", id: habitID, day: day, habitStatus: status)
        return try transaction(operationID: operationID, request: request, scope: scope) { state in
            guard day <= today, var mosaic = state.mosaic,
                  mosaic.habits.contains(where: { $0.id == habitID }) else { throw NivoLifeError.invalidField("habit_day") }
            try NivoTodoRules.validateDay(day)
            Self.markHabit(habitID, day: day, status: status, now: now, in: &mosaic)
            state.mosaic = mosaic
            return true
        }
    }

    /// 封面必须来自本日有效记录，日期形状和心情可独立调整。
    func saveMosaicDay(_ info: NivoMosaicDayInfo, operationID: String, scope: NivoLifeScope) throws -> NivoMosaicDayInfo {
        try transaction(operationID: operationID, request: NivoMosaicRequest(action: "mosaic_day", dayInfo: info), scope: scope) { state in
            try NivoTodoRules.validateDay(info.day)
            var mosaic = state.mosaic ?? NivoMosaicState(ownerKey: scope.ownerKey)
            if let cover = info.coverEntryID {
                guard mosaic.entries.contains(where: { $0.id == cover && $0.day == info.day && $0.deletedAt == nil }) else {
                    throw NivoLifeError.invalidField("cover")
                }
            }
            mosaic.days.removeAll { $0.day == info.day }
            mosaic.days.append(info)
            state.mosaic = mosaic
            return info
        }
    }

    private static func previousEntry(_ draft: NivoMosaicDraft, in mosaic: NivoMosaicState) throws -> NivoMosaicEntry? {
        guard let id = draft.entryID else { return nil }
        guard let previous = mosaic.entries.first(where: { $0.id == id && $0.deletedAt == nil }) else { throw NivoLifeError.notFound(id) }
        try NivoTodoRules.requireRevision(draft.expectedRevision ?? 0, actual: previous.revision ?? 1)
        guard (previous.revision ?? 1) < Int64.max else { throw NivoLifeError.invalidField("revision") }
        return previous
    }

    /// 来源在编辑和恢复中不可换绑或清除，取消关联不改变这条记录的身份。
    private static func requireReflectionIdentity(_ draft: NivoMosaicDraft, in mosaic: NivoMosaicState) throws {
        if let entryID = draft.entryID, let entry = mosaic.entries.first(where: { $0.id == entryID }),
           entry.reflectionSessionID != draft.reflectionSessionID {
            throw NivoLifeError.invalidField("reflection_source")
        }
        if let previous = mosaic.drafts.first(where: { $0.id == draft.id }),
           previous.reflectionSessionID != draft.reflectionSessionID {
            throw NivoLifeError.invalidField("reflection_source")
        }
    }

    /// 默认关联采用当前任务，明确状态保留所见版本，交由既有任务事务校验并执行。
    private static func reflectionLinks(_ input: NivoMosaicDraft, in state: NivoLifeState) throws -> NivoMosaicDraft {
        guard let source = input.reflectionSessionID else { return input }
        if input.entryID == nil {
            guard let session = state.focusSessions.first(where: { $0.id == source && $0.ownerKey == input.ownerKey }),
                  NivoFocusReflectionRules.canReflect(session) else { throw NivoLifeError.notFound("focus_reflection") }
        }
        var draft = input
        let tasks = state.tasks.filter { $0.ownerKey == input.ownerKey && $0.deletedAt == nil && input.taskIDs.contains($0.id) }
        let intents = NivoFocusReflectionRules.taskIntents(input)
        for intent in intents where !tasks.contains(where: { $0.id == intent.taskId }) {
            throw NivoLifeError.notFound(intent.taskId)
        }
        let savedLinks = state.mosaic?.entries.first { $0.id == input.entryID }?.taskSnapshots ?? []
        // 已发布心得保留历史关联；首次保存时仍跳过已删除的待办。
        draft.taskIDs = input.taskIDs.filter { id in tasks.contains { $0.id == id } || savedLinks.contains { $0.id == id } }
        draft.taskSelections = tasks.map { task in
            intents.first { $0.taskId == task.id } ?? NivoTodoSelection(taskId: task.id, expectedRevision: task.revision)
        }
        return draft
    }

    private static func applyMosaicTasks(_ draft: NivoMosaicDraft, old: NivoMosaicEntry?, state: inout NivoLifeState,
                                         now: Int64, today: Int64) throws -> (tasks: [NivoTodoTask], links: [NivoMosaicTaskLink]) {
        var result: [NivoTodoTask] = []
        var links: [NivoMosaicTaskLink] = []
        for id in draft.taskIDs {
            let selection = draft.taskSelections?.first { $0.taskId == id }
            // 普通日记编辑保留当时的名称和进展，只有明确状态意图才重新取当前任务快照。
            if selection?.requestedStatus == nil,
               let oldLink = old?.taskSnapshots?.first(where: { $0.id == id }) {
                links.append(oldLink)
                continue
            }
            guard let index = state.tasks.firstIndex(where: { $0.id == id && $0.deletedAt == nil }) else {
                throw NivoLifeError.notFound(id)
            }
            let previous = state.tasks[index]
            if let selection {
                state.tasks[index] = try applyMosaicTaskSelection(selection, previous: previous, draft: draft,
                                                                now: now, today: today)
            }
            result.append(state.tasks[index])
            let current = state.tasks[index]
            let oldLink = old?.taskSnapshots?.first { $0.id == id }
            // 明确更新任务状态也不改变关联首次保存的时刻，旧关联的未知时间继续为空。
            let linkedAt: Int64?
            if let oldLink { linkedAt = oldLink.linkedAt }
            else { linkedAt = now }
            links.append(NivoMosaicTaskLink(id: current.id, title: current.title, status: current.status, linkedAt: linkedAt))
        }
        return (result, links)
    }

    /// 同状态的日期更正必须有明确标记，旧草稿及普通重复完成继续保持原日期。
    private static func applyMosaicTaskSelection(_ selection: NivoTodoSelection, previous: NivoTodoTask,
                                                draft: NivoMosaicDraft, now: Int64, today: Int64) throws -> NivoTodoTask {
        try NivoTodoRules.requireRevision(selection.expectedRevision, actual: previous.revision)
        if selection.requestedStatus == .done, previous.status == .done, selection.isCompletionDayExplicit == true {
            guard let day = selection.completedDay else { throw NivoLifeError.invalidField("completedDay") }
            return try NivoTodoRules.correctCompletionDay(previous, day: day, owner: draft.ownerKey, now: now, today: today)
        }
        guard let status = selection.requestedStatus, status != previous.status else { return previous }
        var candidate = previous
        candidate.status = status
        candidate.completedDay = selection.completedDay ?? draft.day
        return try NivoTodoRules.update(candidate, previous: previous, owner: draft.ownerKey,
                                       id: previous.id, now: now, today: today)
    }

    private static func mosaicFocus(_ ids: [String], old: NivoMosaicEntry?, in state: NivoLifeState) throws -> [NivoMosaicFocusLink] {
        try ids.map { id in
            // 先取已保存快照，避免编辑正文时用当前会话填补旧记录未知的时间。
            if let snapshot = old?.focusSnapshots?.first(where: { $0.id == id }) { return snapshot }
            if let session = state.focusSessions.first(where: { $0.id == id && $0.deletedAt == nil && $0.status == .finished && $0.mode != .rest }) {
                return NivoMosaicFocusLink(id: id, title: session.title, elapsedMs: session.elapsedMs,
                                          startedAt: session.startedAt, endedAt: session.endedAt)
            }
            throw NivoLifeError.invalidField("focus_link")
        }
    }

    private static func mosaicHabit(_ id: String?, in mosaic: NivoMosaicState) throws -> NivoMosaicHabit? {
        guard let id else { return nil }
        guard let habit = mosaic.habits.first(where: { $0.id == id }) else { throw NivoLifeError.notFound(id) }
        return habit
    }

    private static func markHabit(_ id: String, day: Int64, status: NivoMosaicHabitDay.Status?, now: Int64, in mosaic: inout NivoMosaicState) {
        var marks = mosaic.habitDays ?? []
        marks.removeAll { $0.habitID == id && $0.day == day }
        if let status { marks.append(NivoMosaicHabitDay(habitID: id, day: day, status: status, updatedAt: now)) }
        mosaic.habitDays = marks
    }

    /// 改期只移动没有其他记录支撑的旧标记，未表达勾选意图时保留现有状态。
    private static func applyHabitMark(_ draft: NivoMosaicDraft, old: NivoMosaicEntry?, now: Int64, in mosaic: inout NivoMosaicState) {
        if let habitID = draft.habitID {
            if draft.shouldMarkHabitDone == true {
                markHabit(habitID, day: draft.day, status: .done, now: now, in: &mosaic)
            } else if old != nil, draft.shouldMarkHabitDone == false,
                      mosaic.habitDays?.contains(where: { $0.habitID == habitID && $0.day == draft.day && $0.status == .done }) == true {
                markHabit(habitID, day: draft.day, status: nil, now: now, in: &mosaic)
            }
        }
        guard let old, old.day != draft.day, let oldHabitID = old.habitID else { return }
        let hasAnotherRecord = mosaic.entries.contains {
            $0.id != old.id && $0.day == old.day && $0.habitID == oldHabitID && $0.deletedAt == nil
        }
        if !hasAnotherRecord { markHabit(oldHabitID, day: old.day, status: nil, now: now, in: &mosaic) }
    }

    private static func refreshMosaicDay(day: Int64, mood: NivoMosaicMood?, now: Int64, in mosaic: inout NivoMosaicState) {
        let entries = mosaic.entries.filter { $0.day == day && $0.deletedAt == nil }
        var info = mosaic.days.first { $0.day == day } ?? NivoMosaicDayInfo(day: day, updatedAt: now)
        if !entries.contains(where: { $0.id == info.coverEntryID }) { info.coverEntryID = entries.first?.id }
        if let mood { info.mood = mood }
        info.updatedAt = now
        mosaic.days.removeAll { $0.day == day }
        mosaic.days.append(info)
    }
}
