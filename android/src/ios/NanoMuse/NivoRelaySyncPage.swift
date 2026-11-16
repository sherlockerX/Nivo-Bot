import Foundation

/// 按现有中继协议完整解码分页，缺少消息数组或游标时不能当作成功的空页。
struct NivoRelaySyncPage: Decodable {
    struct Conversation: Decodable {
        let cid: String
        let kind: String
        let title: String?
        let device: String?
        let deviceName: String?
        let createdAt: Int
        let updatedAt: Int
        let deleted: Bool
    }

    struct Attachment: Decodable { let name: String }

    struct Message: Decodable {
        let mid: String
        let cid: String
        let role: String
        let text: String
        let createdAt: Int
        let deleted: Bool
        let device: String?
        let deviceName: String?
        let attachments: [Attachment]?
    }

    let cursor: Int
    let more: Bool
    let conversations: [Conversation]
    let messages: [Message]

    /// 拒绝倒退或无法前进的分页，在任何落库操作前检查整页结构。
    static func decode(_ data: Data, since: Int) throws -> Self {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let page = try decoder.decode(Self.self, from: data)
        guard page.cursor >= since, !page.more || page.cursor > since else { throw NivoLifeError.corruptStore }
        guard page.conversations.allSatisfy({ validID($0.cid) && ["main", "side"].contains($0.kind) }),
              page.messages.allSatisfy({ validID($0.mid) && validID($0.cid)
                  && ["user", "assistant"].contains($0.role) }) else { throw NivoLifeError.corruptStore }
        return page
    }

    private static func validID(_ value: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789._:-")
        return (4...64).contains(value.utf8.count) && value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}

/// 上传必须收到完整回执；无效JSON不能把所有待发消息标记为已知。
struct NivoRelayPushReceipt: Decodable {
    struct Rejection: Decodable {
        let mid: String?
        let cid: String?
        let reason: String
        let cidMain: String?
    }
    let cursor: Int
    let accepted: Int
    let rejected: [Rejection]

    /// 保持现有服务端字段，失败重试继续使用相同消息ID。
    static func decode(_ data: Data) throws -> Self {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let receipt = try decoder.decode(Self.self, from: data)
        guard receipt.cursor >= 0, receipt.accepted >= 0 else { throw NivoLifeError.corruptStore }
        return receipt
    }
}
