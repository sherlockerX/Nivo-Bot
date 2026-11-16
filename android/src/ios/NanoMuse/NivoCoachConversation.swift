import Foundation
import CryptoKit

/// 专题会话的稳定身份。账户和专题共同参与散列，重试不会创建另一条对话。
enum NivoCoachConversationIdentity {
    static let source = NivoMainChatRules.coachSource

    /// 返回合法UUID，继续兼容现有会话数据库、同步和深链格式。
    static func conversation(owner: String, topicID: String) -> String {
        identifier(["coach-topic", owner, topicID])
    }

    /// 每个账户使用自己的系统分组，同名用户分组不参与身份匹配。
    static func folder(owner: String) -> String {
        identifier(["daily-practice", owner])
    }

    private static func identifier(_ parts: [String]) -> String {
        let encoded = parts.map { "\($0.utf8.count):\($0)" }.joined()
        var bytes = Array(SHA256.hash(data: Data(encoded.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15])).uuidString
    }
}

/// 由宿主构造的SQLite事务参数，模型不能自行指定系统分组来源。
struct NivoManagedChatCreation: Sendable {
    let id: String
    let title: String
    let modelID: String
    let modelBinding: String?
    let folderID: String
    let folderName: String
    let memoryEnabled: Bool
}

/// 教练与定时任务共用原子创建参数，保持现有教练调用接口兼容。
typealias NivoCoachChatCreation = NivoManagedChatCreation

/// 创建失败必须回到调用者，不能把未写入的会话当成已创建。
enum NivoCoachConversationError: LocalizedError {
    case identityConflict, deleted, storage, opening
    case archive(String)

    var errorDescription: String? {
        switch self {
        case .identityConflict: return AppLocalized("This practice conversation conflicts with an existing item.")
        case .deleted: return AppLocalized("This practice conversation was deleted. Open the course again to start a new case.")
        case .storage: return AppLocalized("The practice conversation could not be saved. Try again.")
        case .opening: return AppLocalized("A practice conversation is already opening.")
        case .archive(let message): return message
        }
    }
}

extension Notification.Name {
    /// 本地教练事务完成后的投影刷新信号，不携带用户原文。
    static let nivoCoachStateChanged = Notification.Name("nivo.coach.stateChanged")

    /// 聊天来源发生变化时重新核对档案，只携带会话ID。
    static let nivoCoachSourcesChanged = Notification.Name("nivo.coach.sourcesChanged")
}
