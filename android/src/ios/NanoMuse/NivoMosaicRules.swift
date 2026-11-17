import Foundation

/// 碎片、草稿和习惯的值规则供保存、恢复与只读工具共同使用。
enum NivoMosaicRules {
    static let maximumTextLength = 100_000
    static let maximumLinks = 100
    static let binLifetimeMs: Int64 = 7 * 86_400_000
    static let shapes: Set<String> = ["square", "rounded", "circle", "hexagon", "triangle", "heart", "blob1", "blob2", "blob3"]

    /// 习惯单独打卡不需要捏造正文，清空既有记录仍须保留至少一种实际内容。
    static func canSave(_ draft: NivoMosaicDraft) -> Bool {
        hasContent(draft) || (draft.entryID == nil && draft.habitID != nil && draft.shouldMarkHabitDone == true)
    }

    /// 照片、任务和专注关联均可独立构成记录，单独心情留在每日信息中。
    static func hasContent(_ draft: NivoMosaicDraft) -> Bool {
        !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft.mediaPath != nil ||
            !draft.taskIDs.isEmpty || !draft.focusIDs.isEmpty
    }

    /// 恢复前校验账户、唯一标识、日期和媒体路径；出错保留原文件。
    static func validate(_ state: NivoMosaicState, owner: String) throws {
        guard state.ownerKey == owner, state.version == 1,
              unique(state.entries.map(\.id)), unique(state.drafts.map(\.id)),
              unique(state.entries.compactMap(\.reflectionSessionID)),
              unique(state.habits.map(\.id)), unique(state.days.map { String($0.day) }),
              unique((state.habitDays ?? []).map(\.id)) else { throw NivoLifeError.corruptStore }
        for entry in state.entries {
            guard entry.ownerKey == owner, !entry.id.isEmpty, (entry.revision ?? 1) > 0,
                  entry.text.utf16.count <= maximumTextLength else { throw NivoLifeError.corruptStore }
            try validateContent(day: entry.day, path: entry.mediaPath, crop: entry.crop,
                                taskIDs: entry.taskIDs, focusIDs: entry.focusIDs)
            try NivoFocusReflectionRules.validateSource(entry.reflectionSessionID)
            try validateReflectionTaskIntents(entry)
        }
        for draft in state.drafts { try validateDraft(draft, owner: owner) }
        for habit in state.habits { try validateHabit(habit, owner: owner) }
        for day in state.days { try NivoTodoRules.validateDay(day.day) }
        for mark in state.habitDays ?? [] {
            try NivoTodoRules.validateDay(mark.day)
            guard state.habits.contains(where: { $0.id == mark.habitID }) else { throw NivoLifeError.corruptStore }
        }
    }

    /// 保存草稿允许正文为空，但不接受跨账户草稿、越界日期或路径。
    static func validateDraft(_ draft: NivoMosaicDraft, owner: String) throws {
        guard draft.ownerKey == owner else { throw NivoLifeError.accountChanged }
        guard !draft.id.isEmpty, draft.id.utf16.count <= 160,
              draft.text.utf16.count <= maximumTextLength,
              (draft.expectedRevision ?? 0) >= 0 else { throw NivoLifeError.invalidField("fragment") }
        try validateContent(day: draft.day, path: draft.mediaPath, crop: draft.crop,
                            taskIDs: draft.taskIDs, focusIDs: draft.focusIDs)
        try NivoFocusReflectionRules.validateSource(draft.reflectionSessionID)
        if draft.id.hasPrefix("focus-reflection:") || (draft.reflectionSessionID != nil && draft.entryID == nil) {
            guard let identifier = draft.reflectionSessionID,
                  draft.id == NivoFocusReflectionRules.draftID(sessionID: identifier), draft.entryID == nil else {
                throw NivoLifeError.invalidField("reflection_draft")
            }
        }
        let selections = draft.taskSelections ?? []
        guard selections.count <= maximumLinks, unique(selections.map(\.taskId)),
              Set(selections.map(\.taskId)).isSubset(of: Set(draft.taskIDs)),
              selections.allSatisfy({ $0.expectedRevision > 0 }) else { throw NivoLifeError.invalidField("task_selection") }
        for selection in selections { try validateExplicitCompletionDay(selection) }
    }

    /// 旧草稿自动填入的日期不代表更正意图，已完成任务默认展示真实完成日期。
    static func displayedCompletionDay(_ selection: NivoTodoSelection?, task: NivoTodoTask,
                                       defaultDay: Int64) -> Int64 {
        if task.status == .done, selection?.isCompletionDayExplicit != true {
            return task.completedDay ?? defaultDay
        }
        return selection?.completedDay ?? defaultDay
    }

    /// 图片文件仅允许应用自己创建的UUID名称，不接受外部绝对路径。
    static func validateMediaPath(_ path: String?) throws {
        guard let path else { return }
        guard path.hasSuffix(".jpg"), UUID(uuidString: String(path.dropLast(4))) != nil,
              !path.contains("/"), !path.contains("\\") else { throw NivoLifeError.invalidField("photo_path") }
    }

    /// 习惯按历史日程决定当天是否出现，归档从归档日开始生效。
    static func isPlanned(_ habit: NivoMosaicHabit, day: Int64) -> Bool {
        if let archived = habit.archivedDay, day >= archived { return false }
        let startDay = NivoLifeDay.value(Date(timeIntervalSince1970: Double(habit.createdAt) / 1_000))
        let schedule = (habit.schedules ?? []).filter { $0.fromDay <= day }.max { $0.fromDay < $1.fromDay }
        if !(habit.schedules ?? []).isEmpty && schedule == nil { return false }
        guard schedule != nil || day >= startDay else { return false }
        let days = schedule?.weekdays ?? habit.weekdays
        // 公历epoch day的0是周四，日程使用周一为1、周日为7。
        let weekday = Int(((day + 3) % 7 + 7) % 7) + 1
        return days.contains(weekday)
    }

    /// 暂停保留最近的非空日程，恢复时继续使用该日程。
    static func weekdays(_ habit: NivoMosaicHabit, on day: Int64) -> Set<Int> {
        (habit.schedules ?? []).filter { $0.fromDay <= day }.max { $0.fromDay < $1.fromDay }?.weekdays ?? habit.weekdays
    }

    /// 编辑既有记录时带入其版本和裁切视口。
    static func draft(from entry: NivoMosaicEntry, now: Int64, habitDays: [NivoMosaicHabitDay]? = nil) -> NivoMosaicDraft {
        NivoMosaicDraft(ownerKey: entry.ownerKey, id: "edit:" + entry.id, day: entry.day,
                       text: entry.text, mood: entry.mood, taskIDs: entry.taskIDs, focusIDs: entry.focusIDs,
                       mediaPath: entry.mediaPath, entryID: entry.id, updatedAt: now,
                       expectedRevision: entry.revision ?? 1, habitID: entry.habitID,
                       shouldMarkHabitDone: habitDays.map { marks in
                           marks.contains { $0.habitID == entry.habitID && $0.day == entry.day && $0.status == .done }
                       },
                       crop: entry.crop, shape: entry.shape, reflectionSessionID: entry.reflectionSessionID)
    }

    private static func validateContent(day: Int64, path: String?, crop: NivoMosaicCrop?,
                                        taskIDs: [String], focusIDs: [String]) throws {
        try NivoTodoRules.validateDay(day)
        try validateMediaPath(path)
        guard taskIDs.count <= maximumLinks, focusIDs.count <= maximumLinks,
              unique(taskIDs), unique(focusIDs),
              (taskIDs + focusIDs).allSatisfy({ !$0.isEmpty && $0.utf16.count <= 160 }) else {
            throw NivoLifeError.invalidField("links")
        }
        if let crop {
            guard crop.focusX.isFinite, crop.focusY.isFinite, crop.zoom.isFinite,
                  (0...1).contains(crop.focusX), (0...1).contains(crop.focusY),
                  (1...4).contains(crop.zoom) else { throw NivoLifeError.invalidField("crop") }
        }
    }

    /// 已提交意图只描述本条心得的关联任务，备份不能混入无效版本或额外任务。
    private static func validateReflectionTaskIntents(_ entry: NivoMosaicEntry) throws {
        guard let selections = entry.reflectionTaskSelections else { return }
        guard entry.reflectionSessionID != nil, selections.count <= maximumLinks,
              unique(selections.map(\.taskId)), Set(selections.map(\.taskId)).isSubset(of: Set(entry.taskIDs)),
              selections.allSatisfy({ $0.expectedRevision > 0 && $0.requestedStatus != nil }) else {
            throw NivoLifeError.corruptStore
        }
        for selection in selections {
            try validateExplicitCompletionDay(selection)
            if let day = selection.completedDay { try NivoTodoRules.validateDay(day) }
        }
    }

    /// 明确日期必须由输入提供，不能在规范化时用心得日期填补缺失的用户选择。
    private static func validateExplicitCompletionDay(_ selection: NivoTodoSelection) throws {
        guard selection.isCompletionDayExplicit == true else { return }
        guard selection.requestedStatus == .done, let day = selection.completedDay else {
            throw NivoLifeError.invalidField("completedDay")
        }
        try NivoTodoRules.validateDay(day)
    }

    private static func validateHabit(_ habit: NivoMosaicHabit, owner: String) throws {
        guard habit.ownerKey == owner, !habit.id.isEmpty,
              !habit.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              habit.title.utf16.count <= 80, habit.weekdays.isSubset(of: Set(1...7)),
              (habit.revision ?? 1) > 0 else { throw NivoLifeError.corruptStore }
        let schedules = habit.schedules ?? []
        guard unique(schedules.map { String($0.fromDay) }) else { throw NivoLifeError.corruptStore }
        for schedule in schedules {
            try NivoTodoRules.validateDay(schedule.fromDay)
            guard schedule.weekdays.isSubset(of: Set(1...7)) else { throw NivoLifeError.corruptStore }
        }
        if let day = habit.archivedDay { try NivoTodoRules.validateDay(day) }
    }

    private static func unique(_ values: [String]) -> Bool { Set(values).count == values.count }
}

/// 专注心得的来源资格和稳定草稿身份，界面与仓库共用同一判断。
enum NivoFocusReflectionRules {
    /// 已结束的非休息专注可记录心得，零时长保留真实计量，不补造专注时间。
    static func canReflect(_ session: NivoFocusSession) -> Bool {
        session.deletedAt == nil && session.status == .finished && session.mode != .rest
            && session.elapsedMs >= 0 && session.endedAt != nil
    }

    /// 身份与日期分离；账户由仓库和ownerKey隔离，备份换账户后仍能恢复原草稿。
    static func draftID(sessionID: String) -> String {
        "focus-reflection:" + NivoFocusPreferences.ownerHash(sessionID)
    }

    /// 可选来源兼容旧文件，存在时必须是受限长度的有效标识。
    static func validateSource(_ identifier: String?) throws {
        guard let identifier else { return }
        guard !identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              identifier.utf16.count <= 200 else { throw NivoLifeError.invalidField("reflection_source") }
    }

    /// 重复提交忽略请求元数据，明确待办意图必须与已保存回执一致。
    static func hasSameContent(_ draft: NivoMosaicDraft, as entry: NivoMosaicEntry,
                               habitDays: [NivoMosaicHabitDay] = []) -> Bool {
        var saved = NivoMosaicRules.draft(from: entry, now: 0, habitDays: habitDays)
        saved.taskSelections = entry.reflectionTaskSelections
        return content(draft) == content(saved)
    }

    /// 仅保存用户明确选择的状态和所见版本，默认关联不构成任务变更意图。
    static func taskIntents(_ draft: NivoMosaicDraft) -> [NivoTodoSelection] {
        (draft.taskSelections ?? []).filter { $0.requestedStatus != nil }.map { selection in
            var intent = selection
            intent.completedDay = intent.requestedStatus == .done ? intent.completedDay ?? draft.day : nil
            return intent
        }.sorted { $0.taskId < $1.taskId }
    }

    /// 规范化默认显示值与保存时裁剪的首尾空白，保留正文、日期、照片及全部关联。
    private static func content(_ input: NivoMosaicDraft) -> NivoMosaicDraft {
        var draft = input
        draft.id = ""
        draft.entryID = nil
        draft.expectedRevision = nil
        draft.updatedAt = 0
        draft.taskSelections = taskIntents(input)
        draft.text = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.shape = draft.shape ?? "rounded"
        if draft.habitID == nil { draft.shouldMarkHabitDone = nil }
        return draft
    }
}
