import Foundation

/// 任务JSON的容量、语义和合并规则，所有校验在提交前完成。
enum NivoTodoBackupCodec {
    static let maximumBytes = 8_000_000
    static let maximumTasks = 10_000
    static let maximumHistory = NivoTodoBackupHistory.maximumCount

    /// 解码安卓v1/v2和iOS导出的文件，文件内账户不能决定写入归属。
    static func decode(_ data: Data, owner: String, now: Int64, today: Int64) throws -> NivoTodoBackupDocument {
        guard data.count <= maximumBytes else { throw NivoLifeError.invalidField("backup_size") }
        var document = try JSONDecoder().decode(NivoTodoBackupDocument.self, from: data)
        guard document.format == "nanomuse-todo", (1...2).contains(document.version) else {
            throw NivoLifeError.unsupportedVersion(document.version)
        }
        try validateCounts(document)
        guard Set(document.tasks.map(\.id)).count == document.tasks.count,
              Set(document.categories.map(\.id)).count == document.categories.count else { throw NivoLifeError.corruptStore }
        for index in document.tasks.indices {
            document.tasks[index].ownerKey = owner
            try validateTask(document.tasks[index], now: now, today: today)
        }
        for index in document.events.indices { document.events[index].snapshot?.ownerKey = owner }
        var state = NivoLifeState(ownerKey: owner)
        state.tasks = document.tasks
        state.categories = document.categories
        try NivoLifeValidation.validate(state, owner: owner)
        for category in document.categories {
            guard category.createdAt >= 0, category.updatedAt >= 0,
                  category.createdAt < 253_402_300_800_000 else { throw NivoLifeError.corruptStore }
        }
        try validateHistory(document, now: now, today: today)
        return document
    }

    /// 导出包含已删除任务，防止恢复旧备份后把删除当作从未发生。
    static func encode(_ state: NivoLifeState) throws -> Data {
        var history = state.todoHistory ?? NivoTodoBackupHistory()
        let taskIDs = Set(state.tasks.map(\.id))
        for (identifier, receipt) in state.operations where isTodoReceipt(receipt, taskIDs: taskIDs) {
            history.iosReceipts[identifier] = receipt
        }
        let links = (state.mosaic?.entries ?? []).flatMap { entry in
            (entry.taskSnapshots ?? []).filter { taskIDs.contains($0.id) }.map {
                NivoTodoBackupLink(entryId: entry.id, taskId: $0.id, title: $0.title,
                    statusSnapshot: $0.status, linkedAt: entry.updatedAt)
            }
        }
        let categories = state.categories.map { value in
            var category = value
            category.updatedAt = max(category.createdAt, category.updatedAt)
            return category
        }
        history = try NivoTodoPortableHistory.addingReceipts(to: history)
        let document = NivoTodoBackupDocument(tasks: state.tasks, categories: categories, links: links, history: history)
        try validateCounts(document)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(document)
        guard data.count <= maximumBytes else { throw NivoLifeError.invalidField("backup_size") }
        return data
    }

    /// 保留本地同ID任务，导入的删除墓碑同样占用ID，不覆盖本机编辑。
    static func merge(_ document: NivoTodoBackupDocument, into state: inout NivoLifeState, now: Int64) throws -> NivoTodoImportResult {
        let existing = Set(state.tasks.map(\.id))
        let imported = document.tasks.filter { !existing.contains($0.id) }
        let importedIDs = Set(imported.map(\.id))
        state.tasks.append(contentsOf: imported)
        try mergeCategories(document.categories, tasks: imported, into: &state, now: now)
        let missing = try mergeLinks(document.links, importedIDs: importedIDs, state: &state, now: now)
        let archive = NivoTodoBackupHistory(events: document.events, operations: document.operations,
            categoryOperations: document.categoryOperations, iosReceipts: document.iosReceipts)
        state.todoHistory = mergedHistory(local: state.todoHistory, incoming: archive, taskIDs: importedIDs)
        try NivoLifeValidation.validate(state, owner: state.ownerKey)
        return NivoTodoImportResult(imported: imported.count, keptLocal: document.tasks.count - imported.count,
                                    missingEntries: missing)
    }

    /// 历史只用于回顾和再导出，不恢复外部命令的本机授权。
    static func mergedHistory(local: NivoTodoBackupHistory?, incoming: NivoTodoBackupHistory?,
                              taskIDs: Set<String>) -> NivoTodoBackupHistory {
        var result = local ?? NivoTodoBackupHistory()
        guard let incoming else { return result }
        var eventIDs = Set(result.events.map(\.identity))
        for event in incoming.events where taskIDs.contains(event.taskId) && eventIDs.insert(event.identity).inserted {
            result.events.append(event)
        }
        var operationIDs = Set(result.operations.map(\.operationId))
        for operation in incoming.operations where operationIDs.insert(operation.operationId).inserted {
            if let target = operationTaskID(operation), taskIDs.contains(target) { result.operations.append(operation) }
        }
        var categoryIDs = Set(result.categoryOperations.map(\.operationId))
        for operation in incoming.categoryOperations where categoryIDs.insert(operation.operationId).inserted {
            result.categoryOperations.append(operation)
        }
        for (identifier, receipt) in incoming.iosReceipts where result.iosReceipts[identifier] == nil {
            if isTodoReceipt(receipt, taskIDs: taskIDs) { result.iosReceipts[identifier] = receipt }
        }
        return result
    }

    private static func validateCounts(_ document: NivoTodoBackupDocument) throws {
        guard document.tasks.count <= maximumTasks, document.categories.count <= maximumTasks,
              document.links.count <= maximumHistory, document.events.count <= maximumHistory,
              document.operations.count <= maximumHistory, document.categoryOperations.count <= maximumHistory,
              document.iosReceipts.count <= maximumHistory else { throw NivoLifeError.invalidField("backup_size") }
    }

    private static func validateTask(_ task: NivoTodoTask, now: Int64, today: Int64) throws {
        guard !task.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, task.id.utf16.count <= 200,
              task.createdAt >= 0, task.updatedAt >= task.createdAt,
              task.updatedAt < 253_402_300_800_000,
              task.deletedAt.map({ $0 >= 0 && $0 < 253_402_300_800_000 }) ?? true else { throw NivoLifeError.corruptStore }
        if task.status == .done {
            guard let day = task.completedDay, day <= today,
                  let time = task.completedAt, (0...max(0, now)).contains(time) else { throw NivoLifeError.corruptStore }
        }
    }

    private static func validateHistory(_ document: NivoTodoBackupDocument, now: Int64, today: Int64) throws {
        let taskIDs = Set(document.tasks.map(\.id))
        try NivoTodoHistoryValidation.validate(NivoTodoBackupHistory(events: document.events, operations: document.operations,
            categoryOperations: document.categoryOperations, iosReceipts: document.iosReceipts), taskIDs: taskIDs)
        let statuses = Set(NivoTodoStatus.allCases.map(\.rawValue)).union(["deleted"])
        for link in document.links {
            guard taskIDs.contains(link.taskId), !link.entryId.isEmpty, link.entryId.utf16.count <= 200,
                  link.title.utf16.count <= 500, link.linkedAt >= 0 else { throw NivoLifeError.corruptStore }
        }
        for event in document.events {
            if let snapshot = event.snapshot { try validateTask(snapshot, now: now, today: today) }
            guard !event.operationId.isEmpty, event.operationId.utf16.count <= 1_000,
                  taskIDs.contains(event.taskId), statuses.contains(event.status),
                  event.previousStatus.map({ statuses.contains($0) }) ?? true,
                  event.createdAt >= 0, try NivoTodoRules.tags(event.tags) == event.tags else { throw NivoLifeError.corruptStore }
            if let day = event.completedDay {
                try NivoTodoRules.validateDay(day)
                guard day <= today else { throw NivoLifeError.corruptStore }
            }
        }
        for operation in document.operations { try validateOperation(operation, isCategory: false, now: now, today: today) }
        for operation in document.categoryOperations { try validateOperation(operation, isCategory: true, now: now, today: today) }
        for (identifier, receipt) in document.iosReceipts {
            guard !identifier.isEmpty, identifier.utf16.count <= 1_000,
                  isTodoReceipt(receipt, taskIDs: taskIDs),
                  (try JSONSerialization.jsonObject(with: receipt.request)) is [String: Any] else { throw NivoLifeError.corruptStore }
        }
    }

    private static func validateOperation(_ operation: NivoTodoPortableOperation, isCategory: Bool,
                                          now: Int64, today: Int64) throws {
        guard !operation.operationId.isEmpty, operation.operationId.utf16.count <= 1_000,
              operation.createdAt >= 0,
              let result = try JSONSerialization.jsonObject(with: Data(operation.result.utf8)) as? [String: Any] else {
            throw NivoLifeError.corruptStore
        }
        if operation.operationId.hasPrefix("import:"), !isCategory {
            guard operation.request == operation.operationId, let count = result["count"] as? Int, count >= 0 else {
                throw NivoLifeError.corruptStore
            }
            return
        }
        guard let request = try JSONSerialization.jsonObject(with: Data(operation.request.utf8)) as? [String: Any],
              let kind = request["kind"] as? String else { throw NivoLifeError.corruptStore }
        if isCategory {
            guard ["create_category", "delete_category"].contains(kind),
                  let categoryKind = request["categoryKind"] as? String,
                  let category = NivoTodoCategory.Kind(rawValue: categoryKind), let name = request["name"] as? String,
                  result["kind"] as? String == categoryKind, result["name"] as? String == name else { throw NivoLifeError.corruptStore }
            _ = try NivoTodoRules.categoryName(name, kind: category)
        } else {
            guard ["save", "status", "delete"].contains(kind) else { throw NivoLifeError.corruptStore }
            let task = try JSONDecoder().decode(NivoTodoTask.self, from: Data(operation.result.utf8))
            try validateTask(task, now: now, today: today)
            let target = kind == "save" ? (request["task"] as? [String: Any])?["id"] as? String : request["id"] as? String
            guard target == task.id || (kind == "save" && target == "") else { throw NivoLifeError.corruptStore }
        }
    }

    private static func operationTaskID(_ operation: NivoTodoPortableOperation) -> String? {
        (try? JSONDecoder().decode(NivoTodoTask.self, from: Data(operation.result.utf8)))?.id
    }

    private static func isTodoReceipt(_ receipt: NivoLifeOperation, taskIDs: Set<String>) -> Bool {
        let decoder = JSONDecoder()
        if let task = try? decoder.decode(NivoTodoTask.self, from: receipt.result) { return taskIDs.contains(task.id) }
        if (try? decoder.decode(NivoTodoCategory.self, from: receipt.result)) != nil { return true }
        guard let result = try? decoder.decode(NivoTodoToolResult.self, from: receipt.result) else { return false }
        switch result {
        case .task(let task): return taskIDs.contains(task.id)
        case .category: return true
        }
    }

    private static func mergeCategories(_ categories: [NivoTodoCategory], tasks: [NivoTodoTask],
                                         into state: inout NivoLifeState, now: Int64) throws {
        var selected = categories
        for task in tasks where task.deletedAt == nil {
            if !task.groupName.isEmpty { selected.append(NivoTodoCategory(kind: .group, name: task.groupName, createdAt: now, updatedAt: now)) }
            selected.append(contentsOf: task.tags.map { NivoTodoCategory(kind: .tag, name: $0, createdAt: now, updatedAt: now) })
        }
        var identifiers = Set(state.categories.map(\.id))
        for category in selected where identifiers.insert(category.id).inserted {
            _ = try NivoTodoRules.categoryName(category.name, kind: category.kind)
            state.categories.append(category)
        }
        state.categoryGeneration = max(state.categoryGeneration ?? 0, state.categories.map(\.createdAt).max() ?? 0)
    }

    private static func mergeLinks(_ links: [NivoTodoBackupLink], importedIDs: Set<String>,
                                    state: inout NivoLifeState, now: Int64) throws -> Int {
        var mosaic = state.mosaic ?? NivoMosaicState(ownerKey: state.ownerKey)
        let entries = Dictionary(uniqueKeysWithValues: mosaic.entries.enumerated().map { ($0.element.id, $0.offset) })
        var missing = Set<String>()
        var touched = Set<Int>()
        for link in links {
            guard let index = entries[link.entryId], mosaic.entries[index].deletedAt == nil else {
                missing.insert(link.entryId)
                continue
            }
            guard importedIDs.contains(link.taskId), !mosaic.entries[index].taskIDs.contains(link.taskId) else { continue }
            mosaic.entries[index].taskIDs.append(link.taskId)
            var snapshots = mosaic.entries[index].taskSnapshots ?? []
            snapshots.append(NivoMosaicTaskLink(id: link.taskId, title: link.title, status: link.statusSnapshot))
            mosaic.entries[index].taskSnapshots = snapshots
            touched.insert(index)
        }
        for index in touched {
            let revision = mosaic.entries[index].revision ?? 1
            guard revision < Int64.max else { throw NivoLifeError.invalidField("revision") }
            mosaic.entries[index].revision = revision + 1
            mosaic.entries[index].updatedAt = max(mosaic.entries[index].updatedAt, now)
        }
        if !touched.isEmpty { state.mosaic = mosaic }
        return missing.count
    }
}
