import Foundation

/// 个人数据采用保守值合并，同一修订的不同内容返回冲突，不以导入时间伪造新版本。
enum NivoPersonalBackupMerge {
    /// 只改写导入副本的账户，操作回执保留本机版本，旧设备请求不能取得新账户授权。
    static func life(local: NivoLifeState, incoming: NivoLifeState, owner: String) throws -> NivoLifeState {
        try NivoLifeValidation.validate(local, owner: owner)
        try NivoLifeValidation.validate(incoming, owner: incoming.ownerKey)
        let source = rebinding(incoming, owner: owner)
        var result = local
        result.tasks = try merge(local.tasks, source.tasks, key: \.id) { previous, imported in
            if previous.deletedAt != nil { return previous }
            return try versioned(previous, imported, revision: \.revision)
        }
        try mergeFocus(local: local, source: source, result: &result)
        result.categories = categories(local: local, source: source, tasks: result.tasks)
        result.categoryGeneration = max(local.categoryGeneration ?? 0, source.categoryGeneration ?? 0)
        result.storeRevision = max(local.storeRevision ?? 0, source.storeRevision ?? 0)
        result.mosaic = try mosaic(local.mosaic, source.mosaic, owner: owner)
        result.todoHistory = NivoTodoBackupCodec.mergedHistory(local: local.todoHistory, incoming: source.todoHistory,
            taskIDs: Set(result.tasks.map(\.id)))
        try NivoLifeValidation.validate(result, owner: owner)
        return result
    }

    /// 课程和专题没有独立修订时保留本机配置；课次和建课草稿按各自修订比较。
    static func coach(local: NivoCoachState, incoming: NivoCoachState) throws -> NivoCoachState {
        try NivoCoachV2Store.validate(local)
        try NivoCoachV2Store.validate(incoming)
        var result = local
        result.tracks = try merge(local.tracks, incoming.tracks, key: \.id) { previous, _ in previous }
        result.topics = try merge(local.topics, incoming.topics, key: \.id) { previous, imported in
            guard previous.courseID == imported.courseID, previous.unitID == imported.unitID,
                  previous.chatSessionID == imported.chatSessionID else { throw NivoLifeError.operationConflict }
            return previous
        }
        result.sessions = try merge(local.sessions, incoming.sessions, key: \.id) { previous, imported in
            guard previous.course.id == imported.course.id, previous.unitID == imported.unitID,
                  previous.topicID == imported.topicID, previous.chatSessionID == imported.chatSessionID else {
                throw NivoLifeError.operationConflict
            }
            return try versioned(previous, imported, revision: \.revision)
        }
        result.drafts = try merge(local.drafts, incoming.drafts, key: \.id) {
            try versioned($0, $1, revision: \.revision)
        }
        result.actions = try merge(local.actions, incoming.actions, key: \.id) { previous, _ in previous }
        result.revision = max(local.revision, incoming.revision)
        reconcileCoach(&result)
        try NivoCoachV2Store.validate(result)
        return result
    }

    private static func rebinding(_ incoming: NivoLifeState, owner: String) -> NivoLifeState {
        var result = incoming
        result.ownerKey = owner
        result.operations = [:]
        for index in result.tasks.indices { result.tasks[index].ownerKey = owner }
        for index in result.focusSessions.indices { result.focusSessions[index].ownerKey = owner }
        if var history = result.todoHistory {
            for index in history.events.indices { history.events[index].snapshot?.ownerKey = owner }
            result.todoHistory = history
        }
        if var mosaic = result.mosaic {
            mosaic.ownerKey = owner
            for index in mosaic.entries.indices { mosaic.entries[index].ownerKey = owner }
            for index in mosaic.drafts.indices { mosaic.drafts[index].ownerKey = owner }
            for index in mosaic.habits.indices { mosaic.habits[index].ownerKey = owner }
            result.mosaic = mosaic
        }
        return result
    }

    private static func mergeFocus(local: NivoLifeState, source: NivoLifeState, result: inout NivoLifeState) throws {
        let old = Dictionary(uniqueKeysWithValues: local.focusSessions.map { ($0.id, $0) })
        let localSpans = Dictionary(grouping: local.focusSpans, by: \.sessionId)
        let incomingSpans = Dictionary(grouping: source.focusSpans, by: \.sessionId)
        var importedIDs = Set<String>()
        result.focusSessions = try merge(local.focusSessions, source.focusSessions, key: \.id) { previous, imported in
            // 本机正在运行的计时拥有优先权；暂停记录可以接受另一台设备已确认的结束结果。
            if previous.status == .running || previous.deletedAt != nil || imported.status == .running { return previous }
            let selected = try versioned(previous, imported, revision: \.revision)
            if selected != previous { importedIDs.insert(imported.id) }
            else if previous == imported,
                    (localSpans[previous.id] ?? []).sorted(by: { $0.id < $1.id }) != (incomingSpans[previous.id] ?? []).sorted(by: { $0.id < $1.id }) {
                throw NivoLifeError.operationConflict
            }
            return selected
        }
        for index in result.focusSessions.indices where old[result.focusSessions[index].id] == nil {
            let identifier = result.focusSessions[index].id
            importedIDs.insert(identifier)
            if result.focusSessions[index].isActive {
                let confirmedEnd = (incomingSpans[identifier] ?? []).map { $0.startedAt + $0.durationMs }.max()
                result.focusSessions[index].status = .finished
                result.focusSessions[index].endedAt = confirmedEnd ?? result.focusSessions[index].startedAt
                result.focusSessions[index].runningElapsed = 0
                result.focusSessions[index].bootID = "restored"
            }
        }
        result.focusSpans = result.focusSessions.flatMap {
            importedIDs.contains($0.id) ? incomingSpans[$0.id] ?? [] : localSpans[$0.id] ?? []
        }
    }

    private static func categories(local: NivoLifeState, source: NivoLifeState, tasks: [NivoTodoTask]) -> [NivoTodoCategory] {
        var result = local.categories
        var identifiers = Set(result.map(\.id))
        let localTasks = Set(local.tasks.map(\.id))
        let importedTasks = tasks.filter { !localTasks.contains($0.id) && $0.deletedAt == nil }
        let usedGroups = Set(importedTasks.map(\.groupName))
        let usedTags = Set(importedTasks.flatMap(\.tags))
        for category in source.categories where !identifiers.contains(category.id) {
            let isReferenced = category.kind == .group ? usedGroups.contains(category.name) : usedTags.contains(category.name)
            // 分类尚无删除墓碑，旧备份不能复活本机已经删除且没有新任务引用的名称。
            if (local.categoryGeneration ?? 0) >= (source.categoryGeneration ?? 0),
               local.categoryGeneration != nil, !isReferenced { continue }
            result.append(category)
            identifiers.insert(category.id)
        }
        return result
    }

    private static func mosaic(_ local: NivoMosaicState?, _ source: NivoMosaicState?, owner: String) throws -> NivoMosaicState? {
        guard let source else { return local }
        guard var result = local else { return source }
        result.entries = try merge(result.entries, source.entries, key: \.id) { previous, imported in
            if previous.deletedAt != nil { return previous }
            return try ordered(previous, imported, before: previous.revision ?? 1, after: imported.revision ?? 1)
        }
        result.drafts = try merge(result.drafts, source.drafts, key: \.id) {
            try ordered($0, $1, before: $0.updatedAt, after: $1.updatedAt)
        }
        result.habits = try merge(result.habits, source.habits, key: \.id) { previous, imported in
            if previous.archivedDay != nil { return previous }
            return try ordered(previous, imported, before: previous.revision ?? 1, after: imported.revision ?? 1)
        }
        result.days = try merge(result.days, source.days, key: \.day) {
            try ordered($0, $1, before: $0.updatedAt, after: $1.updatedAt)
        }
        result.habitDays = try merge(result.habitDays ?? [], source.habitDays ?? [], key: \.id) {
            try ordered($0, $1, before: $0.updatedAt, after: $1.updatedAt)
        }
        try NivoMosaicRules.validate(result, owner: owner)
        return result
    }

    /// 重新从证据计算掌握，课程版本变化时暂停旧课次并要求复核。
    private static func reconcileCoach(_ result: inout NivoCoachState) {
        for index in result.sessions.indices {
            let session = result.sessions[index]
            let current = result.tracks.first { $0.id == session.course.id }
            if current?.course.version != session.course.version {
                result.sessions[index].requiresCourseReview = true
                if session.status != "complete" { result.sessions[index].status = "paused" }
            }
        }
        for index in result.topics.indices {
            let topic = result.topics[index]
            if let active = topic.activeSessionID,
               !result.sessions.contains(where: { $0.id == active && $0.topicID == topic.id && $0.status == "active" }) {
                result.topics[index].activeSessionID = nil
            }
        }
        let projection = result
        for index in result.tracks.indices {
            let topics = projection.topics.filter { $0.courseID == result.tracks[index].id }
            result.tracks[index].demonstrated = Set(topics.filter {
                NivoCoachTeaching.progress(projection, topicID: $0.id).isDemonstrated
            }.map(\.unitID))
        }
    }

    private static func versioned<Value: Equatable>(_ previous: Value, _ imported: Value,
                                                    revision: KeyPath<Value, Int64>) throws -> Value {
        try ordered(previous, imported, before: previous[keyPath: revision], after: imported[keyPath: revision])
    }

    private static func ordered<Value: Equatable>(_ previous: Value, _ imported: Value,
                                                  before: Int64, after: Int64) throws -> Value {
        if previous == imported || before > after { return previous }
        guard before != after else { throw NivoLifeError.operationConflict }
        return imported
    }

    private static func merge<Value, Key: Hashable>(_ local: [Value], _ incoming: [Value], key: KeyPath<Value, Key>,
                                                    select: (Value, Value) throws -> Value) throws -> [Value] {
        var result = local
        var indices = Dictionary(uniqueKeysWithValues: local.enumerated().map { ($0.element[keyPath: key], $0.offset) })
        for value in incoming {
            let identifier = value[keyPath: key]
            if let index = indices[identifier] { result[index] = try select(result[index], value) }
            else { indices[identifier] = result.count; result.append(value) }
        }
        return result
    }
}
