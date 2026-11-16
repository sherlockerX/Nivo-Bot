import Foundation

/// 工具得到的是宿主已核对的数据库消息，不使用界面临时UUID作为证据身份。
struct NivoSavedUserTurn: Equatable, Sendable {
    let id: String
    let text: String
    let ownerKey: String
    let chatSessionID: String
    let createdAt: Int64
    var sourceDigest: String?
}
