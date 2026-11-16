import Foundation
import SwiftUI

/// 页面释放后仍持有草稿清理入口，实际删除复用提供商的持久凭证协调器。
@MainActor
final class NivoOAuthDraftHost: ObservableObject {
    static let shared = NivoOAuthDraftHost()
    @Published private(set) var needsRecovery = false
    @Published private(set) var isRunning = false
    @Published private(set) var lastCredentialOutcome: NivoCredentialDeletion.Outcome?
    private var completedCleanups: Set<String> = []

    private let registry = NivoOAuthDraftRegistry(fileURL: FileManager.default
        .urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("MinisChat/oauth-drafts.json"))

    /// 登录前先持久登记，已有实例始终排除在草稿清理范围之外。
    func begin(instanceID: String, isExisting: Bool, sourceScope: NivoOAuthScope) throws {
        try NivoOAuthAccess.validateScope(sourceScope)
        try registry.begin(instanceID: instanceID, isExisting: isExisting)
        refreshStatus()
    }

    /// 配置已经确认成功；草稿日志更新失败也不删除已安装凭证。
    func complete(instanceID: String) {
        do { try registry.complete(instanceID: instanceID) }
        catch { registry.abandon(instanceID: instanceID) }
        refreshStatus()
    }

    /// 删除日志仍处于cleaned阶段时终结草稿登记，跨两文件中断也只重放旧回执。
    func settleDeletion(_ journal: NivoProviderDeletion.Journal) throws {
        guard !journal.plan.isCredentialOnly
                || Set(journal.plan.selectedCredentialAccounts) == Set(NivoCredentialDeletion.accounts) else { return }
        try registry.complete(instanceID: journal.plan.instanceID)
        remember(journal.credentialOutcome ?? .init())
        refreshStatus()
    }

    /// 页面退出后由长寿命宿主执行清理，失败保留标识及设置页重试入口。
    func abandon(instanceID: String, after submission: Task<Void, Never>? = nil,
                 onRestoreFinished: @escaping (NivoOAuthScope) -> Void = { _ in }) {
        Task {
            // 保存任务结束前登记保持活动，设置页或其他恢复入口也不能提前清理。
            if let submission { await registry.abandon(instanceID: instanceID, after: submission) }
            else { registry.abandon(instanceID: instanceID) }
            refreshStatus()
            guard needsRecovery else { return }
            guard !isRunning else { return }
            isRunning = true
            defer { isRunning = false; refreshStatus() }
            try? await clean(instanceID: instanceID, onRestoreFinished: onRestoreFinished)
        }
    }

    /// 设置页和启动恢复可重复调用，删除失败不提前移除草稿记录。
    func retry(onRestoreFinished: (NivoOAuthScope) -> Void = { _ in }) async throws {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false; refreshStatus() }
        var identifiers = try registry.pendingIDs()
        let deletion = NivoProviderDeletion(journalURL: NivoProviderDeletionHost.journalURL)
        if let pending = try deletion.pending() {
            if pending.plan.isCredentialOnly, identifiers.contains(pending.plan.instanceID) {
                // 先通过所属草稿恢复旧删除，取得保留回执后立即结束该草稿，不能先丢掉日志再拍快照。
                identifiers.removeAll { $0 == pending.plan.instanceID }
                identifiers.insert(pending.plan.instanceID, at: 0)
            } else {
                let outcome = try await NivoProviderDeletionHost.shared.retry()
                remember(outcome)
                if identifiers.contains(pending.plan.instanceID) {
                    completedCleanups.insert(pending.plan.instanceID)
                }
            }
        }
        for identifier in identifiers {
            try await clean(instanceID: identifier, onRestoreFinished: onRestoreFinished)
        }
    }

    private func clean(instanceID: String, onRestoreFinished: (NivoOAuthScope) -> Void) async throws {
        try await registry.clean(instanceID: instanceID, isInstalled: {
            ProviderConfigStore.shared.instance(for: instanceID) != nil
        }, remove: {
            // 删除已经终结而登记回写失败时，本进程只重试登记，不再取得新凭证快照。
            guard !self.completedCleanups.contains(instanceID) else { return }
            let sourceScope = NivoOAuthAccess.captureScope()
            let outcome = try await NivoProviderDeletionHost.shared.clearDraftCredentials(instanceID: instanceID,
                sourceScope: sourceScope, onRestoreFinished: onRestoreFinished)
            self.completedCleanups.insert(instanceID)
            // 保留属于旧清理意图的终结结果；让登记正常完成，后续自动恢复不得重新删除。
            self.remember(outcome)
        })
        completedCleanups.remove(instanceID)
    }

    private func remember(_ outcome: NivoCredentialDeletion.Outcome) {
        if outcome.hasPreservedCredentials || lastCredentialOutcome == nil { lastCredentialOutcome = outcome }
    }

    /// 无法读取登记文件也需要恢复提示，不能把存储故障当作没有草稿。
    func refreshStatus() {
        do { needsRecovery = try !registry.pendingIDs().isEmpty }
        catch { needsRecovery = true }
    }
}
