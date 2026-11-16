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
              unique(state.habits.map(\.id)), unique(state.days.map { String($0.day) }),
              unique((state.habitDays ?? []).map(\.id)) else { throw NivoLifeError.corruptStore }
        for entry in state.entries {
            guard entry.ownerKey == owner, !entry.id.isEmpty, (entry.revision ?? 1) > 0,
                  entry.text.utf16.count <= maximumTextLength else { throw NivoLifeError.corruptStore }
            try validateContent(day: entry.day, path: entry.mediaPath, crop: entry.crop,
                                taskIDs: entry.taskIDs, focusIDs: entry.focusIDs)
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
        let selections = draft.taskSelections ?? []
        guard selections.count <= maximumLinks, unique(selections.map(\.taskId)),
              Set(selections.map(\.taskId)).isSubset(of: Set(draft.taskIDs)),
              selections.allSatisfy({ $0.expectedRevision > 0 }) else { throw NivoLifeError.invalidField("task_selection") }
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
                       crop: entry.crop, shape: entry.shape)
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
