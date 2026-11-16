import Foundation

/// 所有教练写入的固定协议，调用方必须保留原请求用于精确重试。
struct NivoCoachCommand: Codable, Equatable, Sendable {
    var action: String
    var operationID: String
    var expectedRevision: Int64
    var targetID = ""
    var text = ""
    var payload = ""
}

/// 授权上下文只由聊天宿主创建，模型参数不能声明自己是宿主或改变账户。
struct NivoCoachCommandContext: Sendable {
    var ownerKey: String
    var generation: UUID
    var chatSessionID = ""
    var isMain = true
    var user: NivoSavedUserTurn?
    var isHost = false
}

/// 写入回执固定保存时版本，重放不假称是当前最新状态。
struct NivoCoachCommandResult: Codable, Equatable, Sendable {
    var revision: Int64
    var targetID: String
    var dataJSON: String
    var isReplaySnapshot = false
}

/// 幂等记录包含请求、调用范围和原始回执，避免同一标识被换参数复用。
struct NivoCoachCommandReceipt: Codable, Sendable {
    var request: NivoCoachCommand
    var ownerKey: String
    var chatSessionID: String
    var userMessageID: String
    var isHost: Bool
    var result: NivoCoachCommandResult
}
