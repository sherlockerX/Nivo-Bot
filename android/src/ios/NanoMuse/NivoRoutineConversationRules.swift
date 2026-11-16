import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// 任务与专属对话身份独立于标题和语言，重试不会生成重复对话。
enum NivoRoutineConversationRules {
    static let source = NivoMainChatRules.routineSource

    /// 内置目标检查和旧教练任务沿用其内部会话，不放入用户任务分组。
    static func usesDedicatedConversation(_ row: NanoMuseRoutine) -> Bool {
        let target = row.execution?.target ?? (row.sessionId == nil ? .newSession : .append)
        return !row.hidden && row.goalId == nil && target == .newSession && !(row.script != nil && row.debug == true)
    }

    /// 在第一次创建前即可持久化相同标识；账户相同、任务相同才会复用。
    static func initialSession(owner: String, routineID: String) -> String {
        identifier(["routine-session", owner, routineID])
    }

    /// 分组也按账户隔离，与用户创建的同名分组区别开。
    static func folder(owner: String) -> String { identifier(["scheduled-tasks", owner]) }

    /// 同一运行重试写档案时沿用同一消息，避免重复的脚本结果。
    static func resultMessage(runID: String) -> String { identifier(["scheduled-result", runID]) }

    private static func identifier(_ parts: [String]) -> String {
        let encoded = parts.map { "\($0.utf8.count):\($0)" }.joined()
        var bytes = Array(SHA256.hash(data: Data(encoded.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15])).uuidString
    }
}
