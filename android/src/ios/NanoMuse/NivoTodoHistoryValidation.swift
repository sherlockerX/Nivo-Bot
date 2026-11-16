import Foundation

/// 本地读取、事务提交和整包恢复使用同一历史校验，不让损坏历史绕过JSON导入入口。
enum NivoTodoHistoryValidation {
    static func validate(_ history: NivoTodoBackupHistory, taskIDs: Set<String>) throws {
        let maximum = NivoTodoBackupHistory.maximumCount
        guard history.events.count <= maximum, history.operations.count <= maximum,
              history.categoryOperations.count <= maximum, history.iosReceipts.count <= maximum,
              Set(history.events.map(\.identity)).count == history.events.count,
              Set(history.operations.map(\.operationId)).count == history.operations.count,
              Set(history.categoryOperations.map(\.operationId)).count == history.categoryOperations.count else {
            throw NivoLifeError.corruptStore
        }
        let statuses = Set(NivoTodoStatus.allCases.map(\.rawValue)).union(["deleted"])
        for event in history.events {
            guard !event.operationId.isEmpty, event.operationId.utf16.count <= 1_000,
                  taskIDs.contains(event.taskId), statuses.contains(event.status),
                  event.previousStatus.map({ statuses.contains($0) }) ?? true,
                  (0..<253_402_300_800_000).contains(event.createdAt),
                  try NivoTodoRules.tags(event.tags) == event.tags else { throw NivoLifeError.corruptStore }
            if let day = event.completedDay { try NivoTodoRules.validateDay(day) }
            if let snapshot = event.snapshot {
                guard snapshot.id == event.taskId,
                      (snapshot.deletedAt == nil ? snapshot.status.rawValue : "deleted") == event.status,
                      snapshot.completedDay == event.completedDay,
                      snapshot.completionTags == event.tags else { throw NivoLifeError.corruptStore }
                var state = NivoLifeState(ownerKey: snapshot.ownerKey)
                state.tasks = [snapshot]
                try NivoLifeValidation.validate(state, owner: snapshot.ownerKey)
            }
        }
        for operation in history.operations + history.categoryOperations {
            guard !operation.operationId.isEmpty, operation.operationId.utf16.count <= 1_000,
                  operation.request.utf8.count <= 1_000_000, operation.result.utf8.count <= 1_000_000,
                  (0..<253_402_300_800_000).contains(operation.createdAt),
                  (try JSONSerialization.jsonObject(with: Data(operation.result.utf8))) is [String: Any] else {
                throw NivoLifeError.corruptStore
            }
        }
        for (id, receipt) in history.iosReceipts {
            guard !id.isEmpty, id.utf16.count <= 1_000,
                  receipt.request.count <= 1_000_000, receipt.result.count <= 1_000_000,
                  (try JSONSerialization.jsonObject(with: receipt.request)) is [String: Any],
                  (try JSONSerialization.jsonObject(with: receipt.result)) is [String: Any] else { throw NivoLifeError.corruptStore }
        }
    }
}
