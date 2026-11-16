import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// 安卓仅恢复带配套回执的事件；iOS用独立命名空间导出真实快照，不伪造用户命令。
enum NivoTodoPortableHistory {
    static func addingReceipts(to source: NivoTodoBackupHistory) throws -> NivoTodoBackupHistory {
        var history = source
        var existing = Set(history.operations.map(\.operationId))
        for index in history.events.indices {
            let event = history.events[index]
            guard !existing.contains(event.operationId), let snapshot = event.snapshot else { continue }
            let digest = SHA256.hash(data: Data(event.identity.utf8)).map { String(format: "%02x", $0) }.joined()
            let identifier = "ios-history:" + digest
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let result = try encoder.encode(snapshot)
            let task = try JSONSerialization.jsonObject(with: result)
            // origin不属于安卓实际写请求，回执只能归档，不能匹配新的执行请求。
            let request = try JSONSerialization.data(withJSONObject: ["kind": "save", "task": task, "origin": "ios-history"], options: [.sortedKeys])
            if existing.insert(identifier).inserted {
                history.operations.append(NivoTodoPortableOperation(operationId: identifier,
                    request: String(decoding: request, as: UTF8.self), result: String(decoding: result, as: UTF8.self), createdAt: event.createdAt))
            }
            history.events[index].operationId = identifier
        }
        return history
    }
}
