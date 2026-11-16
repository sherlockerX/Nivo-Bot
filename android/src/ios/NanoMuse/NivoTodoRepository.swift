import Foundation

/// 待办写入请求保留原始版本，重试不能被当前数据库内容改写。
private struct NivoTodoSaveRequest: Codable {
    var action = "save_todo"
    var task: NivoTodoTask
}

/// 状态命令与编辑命令的幂等签名互不混淆。
private struct NivoTodoStatusRequest: Codable {
    var action: String
    var id: String
    var expectedRevision: Int64
    var status: NivoTodoStatus?
    var completedDay: Int64?
}

/// 分类删除使用创建时间作为代次，避免误删同名新建分类。
private struct NivoCategoryRequest: Codable {
    var action: String
    var kind: NivoTodoCategory.Kind
    var name: String
    var expectedCreatedAt: Int64?
}

extension NivoLifeRepository {
    /// 工具请求直接进入串行事务，回放检查不依赖已变化或已删除的界面对象。
    func executeTodoTool(_ request: NivoTodoToolCommand, operationID: String, scope: NivoLifeScope,
                         now: Int64, today: Int64) throws -> NivoTodoToolResult {
        try executeTodoToolResult(request, operationID: operationID, scope: scope, now: now, today: today).value
    }

    /// 工具输出区分首次提交与精确回放，当前状态由调用方另外读取。
    func executeTodoToolResult(_ request: NivoTodoToolCommand, operationID: String, scope: NivoLifeScope,
                              now: Int64, today: Int64) throws -> NivoLifeTransactionResult<NivoTodoToolResult> {
        try transactionResult(operationID: operationID, request: request, scope: scope) { state in
            if request.action == "create_category" || request.action == "delete_category" {
                return .category(try Self.applyToolCategory(request, state: &state, now: now))
            }
            return .task(try Self.applyToolTask(request, state: &state, owner: scope.ownerKey, now: now, today: today))
        }
    }

    private static func applyToolCategory(_ request: NivoTodoToolCommand, state: inout NivoLifeState,
                                           now: Int64) throws -> NivoTodoCategory {
        guard let kind = request.categoryKind, let rawName = request.categoryName else { throw NivoLifeError.invalidField("category") }
        let name = try NivoTodoRules.categoryName(rawName, kind: kind)
        if request.action == "create_category" { return try rememberCategory(kind: kind, name: name, state: &state, now: now) }
        guard let expected = request.expectedCreatedAt,
              let index = state.categories.firstIndex(where: { $0.kind == kind && $0.name == name }) else { throw NivoLifeError.notFound("category") }
        let category = state.categories[index]
        try NivoTodoRules.requireRevision(expected, actual: category.createdAt)
        state.categories.remove(at: index)
        try removeCategoryReferences(category, state: &state, now: now)
        return category
    }

    private static func applyToolTask(_ request: NivoTodoToolCommand, state: inout NivoLifeState,
                                      owner: String, now: Int64, today: Int64) throws -> NivoTodoTask {
        let previous: NivoTodoTask?
        if request.action == "create" { previous = nil }
        else {
            guard let expected = request.expectedRevision else { throw NivoLifeError.invalidField("expectedRevision") }
            previous = try task(id: request.targetID, revision: expected, in: state)
        }
        var input = previous ?? NivoTodoTask(ownerKey: owner)
        switch request.action {
        case "create", "update": request.patch.apply(to: &input)
        case "start": input.status = .inProgress
        case "complete": input.status = .done; input.completedDay = request.completedDay
        case "reopen": input.status = .todo
        case "delete":
            guard input.revision < Int64.max else { throw NivoLifeError.invalidField("revision") }
            input.deletedAt = now
            input.updatedAt = max(input.updatedAt, now)
            input.revision += 1
            replaceTask(input, in: &state)
            return input
        default: throw NivoLifeError.invalidField("todo_action")
        }
        let result = try NivoTodoRules.update(input, previous: previous, owner: owner,
            id: previous?.id ?? UUID().uuidString, now: now, today: today)
        replaceTask(result, in: &state)
        try rememberCategories(for: result, state: &state, now: now)
        return result
    }

    /// 保存新任务或完整编辑，版本校验和写入属于同一串行事务。
    func saveTask(
        _ input: NivoTodoTask, operationID: String, scope: NivoLifeScope,
        now: Int64, today: Int64
    ) throws -> NivoTodoTask {
        try transaction(operationID: operationID, request: NivoTodoSaveRequest(task: input), scope: scope) { state in
            let previous = state.tasks.first { $0.id == input.id }
            if !input.id.isEmpty {
                guard let previous, previous.deletedAt == nil else { throw NivoLifeError.notFound("task") }
                try NivoTodoRules.requireRevision(input.revision, actual: previous.revision)
            }
            let result = try NivoTodoRules.update(
                input, previous: previous, owner: scope.ownerKey,
                id: previous?.id ?? UUID().uuidString, now: now, today: today
            )
            Self.replaceTask(result, in: &state)
            try Self.rememberCategories(for: result, state: &state, now: now)
            return result
        }
    }

    /// 用户直接操作和通过原话校验的AI命令共用状态事务。
    func changeTaskStatus(
        id: String, status: NivoTodoStatus, expectedRevision: Int64, completedDay: Int64? = nil,
        operationID: String, scope: NivoLifeScope, now: Int64, today: Int64
    ) throws -> NivoTodoTask {
        let request = NivoTodoStatusRequest(
            action: "todo_status", id: id, expectedRevision: expectedRevision,
            status: status, completedDay: completedDay
        )
        return try transaction(operationID: operationID, request: request, scope: scope) { state in
            let previous = try Self.task(id: id, revision: expectedRevision, in: state)
            var input = previous
            input.status = status
            input.completedDay = completedDay
            let result = try NivoTodoRules.update(
                input, previous: previous, owner: scope.ownerKey, id: id, now: now, today: today
            )
            Self.replaceTask(result, in: &state)
            return result
        }
    }

    /// 软删除保留完成快照用于历史关联，统计过滤已删除任务。
    func deleteTask(
        id: String, expectedRevision: Int64, operationID: String, scope: NivoLifeScope, now: Int64
    ) throws -> NivoTodoTask {
        let request = NivoTodoStatusRequest(action: "delete_todo", id: id, expectedRevision: expectedRevision)
        return try transaction(operationID: operationID, request: request, scope: scope) { state in
            var result = try Self.task(id: id, revision: expectedRevision, in: state)
            guard result.revision < Int64.max else { throw NivoLifeError.invalidField("revision") }
            result.deletedAt = now
            result.updatedAt = max(result.updatedAt, now)
            result.revision += 1
            Self.replaceTask(result, in: &state)
            return result
        }
    }

    /// 创建可复用分类，重复创建返回既有分类但不会伪造新创建时间。
    func createCategory(
        kind: NivoTodoCategory.Kind, name: String, operationID: String, scope: NivoLifeScope, now: Int64
    ) throws -> NivoTodoCategory {
        let normalized = try NivoTodoRules.categoryName(name, kind: kind)
        let request = NivoCategoryRequest(action: "create_category", kind: kind, name: normalized)
        return try transaction(operationID: operationID, request: request, scope: scope) { state in
            try Self.rememberCategory(kind: kind, name: normalized, state: &state, now: now)
        }
    }

    /// 删除目录并清除当前任务引用，历史完成标签和专注快照保持原样。
    func deleteCategory(
        kind: NivoTodoCategory.Kind, name: String, expectedCreatedAt: Int64,
        operationID: String, scope: NivoLifeScope, now: Int64
    ) throws -> NivoTodoCategory {
        let normalized = try NivoTodoRules.categoryName(name, kind: kind)
        let request = NivoCategoryRequest(
            action: "delete_category", kind: kind, name: normalized, expectedCreatedAt: expectedCreatedAt
        )
        return try transaction(operationID: operationID, request: request, scope: scope) { state in
            guard let index = state.categories.firstIndex(where: { $0.kind == kind && $0.name == normalized }) else {
                throw NivoLifeError.notFound("category")
            }
            let category = state.categories[index]
            try NivoTodoRules.requireRevision(expectedCreatedAt, actual: category.createdAt)
            state.categories.remove(at: index)
            try Self.removeCategoryReferences(category, state: &state, now: now)
            return category
        }
    }

    private static func task(id: String, revision: Int64, in state: NivoLifeState) throws -> NivoTodoTask {
        guard let task = state.tasks.first(where: { $0.id == id && $0.deletedAt == nil }) else {
            throw NivoLifeError.notFound("task")
        }
        try NivoTodoRules.requireRevision(revision, actual: task.revision)
        return task
    }

    private static func replaceTask(_ task: NivoTodoTask, in state: inout NivoLifeState) {
        if let index = state.tasks.firstIndex(where: { $0.id == task.id }) { state.tasks[index] = task }
        else { state.tasks.append(task) }
    }

    private static func rememberCategories(for task: NivoTodoTask, state: inout NivoLifeState, now: Int64) throws {
        if !task.groupName.isEmpty {
            let group = try NivoTodoRules.categoryName(task.groupName, kind: .group)
            _ = try rememberCategory(kind: .group, name: group, state: &state, now: now)
        }
        for tag in task.tags {
            let name = try NivoTodoRules.categoryName(tag, kind: .tag)
            _ = try rememberCategory(kind: .tag, name: name, state: &state, now: now)
        }
    }

    private static func rememberCategory(
        kind: NivoTodoCategory.Kind, name: String, state: inout NivoLifeState, now: Int64
    ) throws -> NivoTodoCategory {
        if let category = state.categories.first(where: { $0.kind == kind && $0.name == name }) { return category }
        let previous = state.categoryGeneration ?? state.categories.map(\.createdAt).max() ?? 0
        guard previous < Int64.max else { throw NivoLifeError.invalidField("categoryGeneration") }
        let generation = max(now, previous + 1)
        state.categoryGeneration = generation
        let category = NivoTodoCategory(kind: kind, name: name, createdAt: generation, updatedAt: max(now, generation))
        state.categories.append(category)
        return category
    }

    private static func removeCategoryReferences(
        _ category: NivoTodoCategory, state: inout NivoLifeState, now: Int64
    ) throws {
        for index in state.tasks.indices {
            var task = state.tasks[index]
            guard task.deletedAt == nil else { continue }
            let matches = category.kind == .group ? task.groupName == category.name : task.tags.contains(category.name)
            guard matches else { continue }
            if category.kind == .group { task.groupName = "" }
            else { task.tags.removeAll { $0 == category.name } }
            guard task.revision < Int64.max else { throw NivoLifeError.invalidField("revision") }
            task.revision += 1
            task.updatedAt = max(task.updatedAt, now)
            state.tasks[index] = task
        }
    }
}
