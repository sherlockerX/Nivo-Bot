import Foundation

/// 拒绝损坏或伪造的持久化状态，避免异常时间戳溢出和统计虚增。
enum NivoLifeValidation {
    static let maximumStoreBytes = 64 * 1_024 * 1_024

    /// 加载和导入共用校验，错误由宿主提示，原文件不会被空状态覆盖。
    static func validate(_ state: NivoLifeState, owner: String) throws {
        guard state.version == 1 else { throw NivoLifeError.unsupportedVersion(state.version) }
        guard state.ownerKey == owner, (state.storeRevision ?? 0) >= 0,
              Set(state.tasks.map(\.id)).count == state.tasks.count,
              Set(state.categories.map(\.id)).count == state.categories.count,
              Set(state.focusSessions.map(\.id)).count == state.focusSessions.count,
              Set(state.focusSpans.map(\.id)).count == state.focusSpans.count,
              state.focusSessions.filter(\.isActive).count <= 1 else { throw NivoLifeError.corruptStore }
        try state.tasks.forEach { try validateTask($0, owner: owner) }
        for category in state.categories {
            guard category.createdAt >= 0, category.updatedAt >= category.createdAt,
                  category.updatedAt < 253_402_300_800_000,
                  try NivoTodoRules.categoryName(category.name, kind: category.kind) == category.name else {
                throw NivoLifeError.corruptStore
            }
        }
        try validateFocus(state, owner: owner)
        if let history = state.todoHistory { try NivoTodoHistoryValidation.validate(history, taskIDs: Set(state.tasks.map(\.id))) }
        if let mosaic = state.mosaic { try NivoMosaicRules.validate(mosaic, owner: owner) }
    }

    private static func validateTask(_ task: NivoTodoTask, owner: String) throws {
        guard task.ownerKey == owner, !task.id.isEmpty, task.revision > 0,
              task.id.utf16.count <= 200, task.createdAt >= 0, task.updatedAt >= task.createdAt,
              task.updatedAt < 253_402_300_800_000,
              !task.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              task.title.utf16.count <= 500, task.notes.utf16.count <= 100_000,
              task.groupName.utf16.count <= 200,
              try NivoTodoRules.tags(task.tags) == task.tags,
              try NivoTodoRules.tags(task.completionTags) == task.completionTags else { throw NivoLifeError.corruptStore }
        try [task.scheduledDay, task.dueDay, task.completedDay].compactMap { $0 }.forEach(NivoTodoRules.validateDay)
        if task.status == .done {
            guard task.completedDay != nil, task.completedAt != nil else { throw NivoLifeError.corruptStore }
        } else if task.completedDay != nil || task.completedAt != nil || !task.completionTags.isEmpty {
            throw NivoLifeError.corruptStore
        }
    }

    private static func validateFocus(_ state: NivoLifeState, owner: String) throws {
        let byID = Dictionary(uniqueKeysWithValues: state.focusSessions.map { ($0.id, $0) })
        var measured: [String: Int64] = [:]
        for span in state.focusSpans {
            guard byID[span.sessionId] != nil, !span.id.isEmpty,
                  span.durationMs > 0, span.durationMs <= NivoFocusRules.maximumSessionMs,
                  span.startedAt >= -62_135_596_800_000,
                  span.startedAt <= 253_402_300_799_999 - span.durationMs else { throw NivoLifeError.corruptStore }
            let sum = (measured[span.sessionId] ?? 0).addingReportingOverflow(span.durationMs)
            guard !sum.overflow, sum.partialValue <= NivoFocusRules.maximumSessionMs else { throw NivoLifeError.corruptStore }
            measured[span.sessionId] = sum.partialValue
        }
        for session in state.focusSessions {
            guard session.ownerKey == owner, !session.id.isEmpty, session.revision > 0,
                  session.targetMs > 0, session.targetMs <= NivoFocusRules.maximumSessionMs,
                  session.elapsedMs >= 0, session.elapsedMs <= session.targetMs,
                  session.runningElapsed >= 0, !session.bootID.isEmpty,
                  session.runningWall >= -62_135_596_800_000,
                  session.runningWall <= 253_402_300_799_999 - session.targetMs,
                  session.elapsedMs == (measured[session.id] ?? 0),
                  (session.status == .finished) == (session.endedAt != nil),
                  session.deletedAt == nil || session.status == .finished else { throw NivoLifeError.corruptStore }
        }
    }
}
