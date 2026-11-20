import Foundation

/// 备份和恢复的账户租约，跨异步调用始终指向同一次冻结。
struct NivoPersonalBackupLease: Sendable {
    var id: UUID
    var ownerKey: String
    var life: NivoLifeState
    var portableLife: NivoLifeState
    var coach: NivoCoachState
    var archives: [NivoCoachArchiveEntry]
    var selectedBackground: String
}

/// 入口失败保留原数据，并向用户说明何时可以重试。
extension NivoPersonalBackupError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .busy: return AppLocalized("Personal data is being backed up or restored. Try again when it finishes.")
        case .chatRunning: return AppLocalized("Finish the current chat before backing up personal data.")
        case .snapshotChanged: return AppLocalized("Personal data changed after this backup started. Start a new backup.")
        case .invalidPackage: return AppLocalized("Saved data could not be opened. The original file was preserved.")
        }
    }
}

/// 主线程封闭页面、聊天和账户切换入口，仓库actor另外验证租约，避免只锁住界面。
@MainActor
enum NivoPersonalBackupAccess {
    private(set) static var token: UUID?
    private static var providerRestoreToken: UUID?
    private static var accountWaiters: [CheckedContinuation<Void, Never>] = []
    private static var transitionCompletionWaiters: [CheckedContinuation<Void, Never>] = []
    private static var accountTransitions = 0
    private static let transitionLock = NivoAccountTransitionLock()
    private static var hasActiveLease: Bool { token != nil || providerRestoreToken != nil }
    static var isBusy: Bool { hasActiveLease || NivoProviderDeletionHost.hasPendingRecovery }
    /// 登录网络等待和排队切号同样占用身份边界。
    static var hasAccountTransition: Bool { accountTransitions > 0 }

    /// 已经开始的聊天必须先结束，防止正文与教练档案落入两个时间点。
    static func begin() async throws -> NivoPersonalBackupLease {
        guard !EnvVarStore.hasPendingRecovery else { throw NivoPersonalBackupError.busy }
        guard !isBusy, accountTransitions == 0, !NanoMuseAccountData.shared.isChangingAccount else {
            throw NivoPersonalBackupError.busy
        }
        let life = NivoLifeModel.shared
        await life.activate()
        guard !isBusy, accountTransitions == 0 else { throw NivoPersonalBackupError.busy }
        guard let scope = life.accessScope, !life.isBusy else { throw NivoPersonalBackupError.busy }
        guard !NanoMuseSync.shared.syncing, !NivoCloudInboundCheckpoint.shared.isBusy, !NivoCloudExportAccess.isBusy else {
            throw NivoPersonalBackupError.busy
        }
        guard !EnvVarStore.hasPendingRecovery else { throw NivoPersonalBackupError.busy }
        guard SessionActivityTracker.shared.resolvedActiveSessionIds.isEmpty,
              !NivoCoachArchiveWrites.isBusy, NanoMuseScheduler.shared.running.isEmpty,
              !NivoScheduledRunScopes.shared.isBusy else { throw NivoPersonalBackupError.chatRunning }
        let identifier = UUID()
        token = identifier
        NivoOAuthAccess.invalidateAll()
        life.beginBackupFreeze()
        do {
            try NanoMuseScheduler.shared.requireReadable()
            try await ISHExecutionCoordinator.shared.prepareHomeForBackup()
            let snapshot = try await life.repository.beginBackup(scope: scope, token: identifier, clock: NivoLifeClock.sample())
            let coach = try await NivoCoachV2Store.shared.beginBackup(ownerKey: scope.ownerKey, token: identifier)
            await NivoFocusBackgroundStore.shared.revoke()
            await NivoMosaicStore.shared.close()
            guard token == identifier, NanoMuseAccountData.shared.current == scope.ownerKey else { throw NivoLifeError.accountChanged }
            let live = try await life.repository.backupLiveState(token: identifier)
            return NivoPersonalBackupLease(id: identifier, ownerKey: scope.ownerKey, life: live, portableLife: snapshot,
                coach: coach.state, archives: coach.archives,
                selectedBackground: NivoFocusPreferences.background(owner: scope.ownerKey))
        } catch {
            await end(identifier)
            throw error
        }
    }

    /// 成功和失败都等待仓库解冻、重载完成，再放行排队的账户切换。
    static func end(_ identifier: UUID) async {
        guard token == identifier else { return }
        await NivoLifeModel.shared.repository.endBackup(token: identifier)
        await NivoCoachV2Store.shared.endBackup(token: identifier)
        await NivoLifeModel.shared.endBackupFreeze()
        NanoMuseScheduler.shared.reload()
        token = nil
        resumeAccountWaitersIfIdle()
    }

    /// 只恢复提供商时也冻结账户和入站写入；完整备份可以在同一租约内嵌套使用。
    static func beginProviderRestore(personalLeaseID: UUID?, allowingProviderDeletionRecovery: Bool = false) throws -> UUID {
        guard !EnvVarStore.hasPendingRecovery else { throw NivoPersonalBackupError.busy }
        guard allowingProviderDeletionRecovery || !NivoProviderDeletionHost.hasPendingRecovery else { throw NivoPersonalBackupError.busy }
        guard providerRestoreToken == nil, token == personalLeaseID, accountTransitions == 0,
              NanoMuseAccountData.shared.isReady, !NanoMuseAccountData.shared.isChangingAccount else {
            throw NivoPersonalBackupError.busy
        }
        if token == nil {
            guard !NanoMuseSync.shared.syncing, !NivoCloudInboundCheckpoint.shared.isBusy, !NivoCloudExportAccess.isBusy else {
                throw NivoPersonalBackupError.busy
            }
            guard SessionActivityTracker.shared.resolvedActiveSessionIds.isEmpty,
                  NanoMuseScheduler.shared.running.isEmpty, !NivoScheduledRunScopes.shared.isBusy,
                  !NanoMuseCallSession.isActive else { throw NivoPersonalBackupError.chatRunning }
        }
        let identifier = UUID()
        providerRestoreToken = identifier
        NivoOAuthAccess.invalidateAll()
        return identifier
    }

    /// 缓存和镜像处理结束后才让等候的账户切换继续。
    static func endProviderRestore(_ identifier: UUID) {
        guard providerRestoreToken == identifier else { return }
        providerRestoreToken = nil
        resumeAccountWaitersIfIdle()
    }

    private static func resumeAccountWaitersIfIdle() {
        guard !hasActiveLease else { return }
        let waiters = accountWaiters
        accountWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    /// 账户生命周期等待文件事务退出，不能在备份回滚期间删除同一账户目录。
    static func waitForAccountAccess() async {
        guard hasActiveLease else { return }
        await withCheckedContinuation { accountWaiters.append($0) }
    }

    /// 身份切换内的网络等待也占用边界，不能在密钥和账户文件之间开始备份。
    static func beginAccountChange() async {
        // 待恢复日志不是活动租约，启动必须能够取得账户锁来重放，不能等待自身清理日志。
        while hasActiveLease { await waitForAccountAccess() }
        accountTransitions += 1
        NivoOAuthAccess.invalidateAll()
        await transitionLock.acquire()
    }

    /// 只供独立启动任务等待；恢复持有者不能等待自己的退出，也不申请新的账户租约。
    static func waitForAccountTransitionToFinish() async {
        while hasAccountTransition {
            await withCheckedContinuation { transitionCompletionWaiters.append($0) }
        }
    }

    /// 排队切换同样阻止备份开始，最后一次切换结束后才恢复备份入口。
    static func endAccountChange() {
        accountTransitions = max(0, accountTransitions - 1)
        transitionLock.release()
        if accountTransitions == 0 {
            let waiters = transitionCompletionWaiters
            transitionCompletionWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
    }
}
