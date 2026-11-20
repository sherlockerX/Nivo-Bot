import Foundation
import UIKit

/// 将沙盒命令绑定到内核传入的会话上下文，参数不能自报账户或聊天身份。
@objc(NivoJigsawOffloadBridge)
final class NivoJigsawOffloadBridge: NSObject {
    /// 调用方在客体线程有界等待；主线程只做授权，读取和输出不阻塞界面。
    @objc static func execute(arguments: [String], context: UInt64,
                              completion: @escaping @Sendable (String, Int32) -> Void) {
        let deadline = ProcessInfo.processInfo.systemUptime + 15
        Task { @MainActor in
            do {
                let query = try NivoJigsawQuery.parse(arguments)
                guard let sessionID = MinisFsRouter.shared.sid(for: context) else {
                    throw NivoJigsawExecutionError.hostConversationRequired
                }
                let life = NivoLifeModel.shared
                guard let scope = life.accessScope else { throw NivoPersonalRecordsAccessError.dataNotReady }
                try await NivoMosaicReadAccess.authorize(sessionID: sessionID, scope: scope,
                    command: "minis-jigsaw-cli " + arguments.joined(separator: " "))
                guard ProcessInfo.processInfo.systemUptime < deadline else {
                    throw NivoJigsawExecutionError.timedOut
                }
                let state = try await life.repository.mosaicSnapshot(scope: scope)
                let output = try await Task.detached(priority: .userInitiated) {
                    try NivoJigsawOutput.render(query: query, state: state)
                }.value
                try NivoMosaicReadAccess.requireCurrent(sessionID: sessionID, scope: scope)
                guard ProcessInfo.processInfo.systemUptime < deadline else {
                    throw NivoJigsawExecutionError.timedOut
                }
                completion(output + "\n", 0)
            } catch {
                completion(NivoLifeToolFailure.output(error) + "\n", error is NivoJigsawQuery.QueryError ? 2 : 1)
            }
        }
    }
}

/// 直接工具和原生命令共用权限，子进程和绝对路径也必须通过同一检查。
@MainActor
enum NivoMosaicReadAccess {
    static let commandName = "minis-jigsaw-cli"

    /// 授权提示结束后再次核对账户，旧页面的许可不能用于新账户。
    static func authorize(sessionID: String, scope: NivoLifeScope, command: String) async throws {
        try requireCurrent(sessionID: sessionID, scope: scope)
        let permission = await OffloadPermissionManager.shared.checkPermission(
            for: commandName, sessionId: sessionID, fullCommand: command)
        guard case .allowed = permission else {
            throw NivoJigsawExecutionError.permissionDenied
        }
        try requireCurrent(sessionID: sessionID, scope: scope)
    }

    /// 主对话和已绑定专题可以读取，其他会话、后台和账户切换期间均拒绝。
    static func requireCurrent(sessionID: String, scope: NivoLifeScope) throws {
        let life = NivoLifeModel.shared
        guard UIApplication.shared.applicationState == .active else { throw NivoPersonalRecordsAccessError.foregroundRequired }
        guard life.isMosaicReady else { throw NivoPersonalRecordsAccessError.dataNotReady }
        guard life.accessScope == scope, scope.ownerKey == NanoMuseAccountData.shared.current,
              NanoMuseSync.shared.shows(sessionID) else { throw NivoPersonalRecordsAccessError.accountChanged }
        guard sessionID == UserDefaults.standard.string(forKey: NanoMuseMainChat.key) ||
                NivoCoachChatContext.shared.isPractice(sessionID) else { throw NivoPersonalRecordsAccessError.conversationRestricted }
    }
}
