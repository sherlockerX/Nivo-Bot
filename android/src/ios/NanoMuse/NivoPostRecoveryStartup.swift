import Foundation

/// 恢复成功后按顺序执行一次启动初始化，重入只返回，不等待自己创建的任务。
@MainActor
final class NivoPostRecoveryStartup {
    static let shared = NivoPostRecoveryStartup()
    private var isRunning = false
    private var hasAttemptedInitialization = false

    /// 等待账户任务及恢复锁结束；失败恢复不消耗本次进程的初始化机会。
    func run(waitForRecovery: @MainActor () async -> Bool,
             recoverOAuthDrafts: @MainActor () async -> Void,
             prepareModels: @MainActor () async -> Void) async {
        guard !isRunning, !hasAttemptedInitialization else { return }
        isRunning = true
        defer { isRunning = false }
        guard await waitForRecovery() else { return }
        hasAttemptedInitialization = true
        await recoverOAuthDrafts()
        await prepareModels()
    }
}

#if canImport(UIKit)
extension NivoPostRecoveryStartup {
    /// 由App生命周期单独调度，账户恢复本身不等待此操作，模型迁移可以安全复用start。
    static func activateAfterAccountRecovery() async {
        await shared.run(waitForRecovery: {
            await NanoMuseAccountData.shared.start()
            await NivoPersonalBackupAccess.waitForAccountTransitionToFinish()
            return NanoMuseAccountData.shared.isReady && !NanoMuseAccountData.shared.isChangingAccount
        }, recoverOAuthDrafts: {
            NivoOAuthDraftHost.shared.refreshStatus()
            try? await NivoOAuthDraftHost.shared.retry()
        }, prepareModels: {
            await ProviderMigration.prepareModels(store: ProviderConfigStore.shared)
        })
    }
}
#endif
