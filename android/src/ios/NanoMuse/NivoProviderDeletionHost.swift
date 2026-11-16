import Foundation
import SwiftUI

/// 普通删除及冷启动恢复共用一个入口，账户退出借用已经持有的身份切换租约。
@MainActor
final class NivoProviderDeletionHost: ObservableObject {
    static let shared = NivoProviderDeletionHost()
    @Published private(set) var isRunning = false
    @Published private(set) var needsRecovery = false
    @Published private(set) var lastCredentialOutcome: NivoCredentialDeletion.Outcome?

    static var journalURL: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MinisChat/provider-deletion.json")
    }

    /// 只读取是否存在；内容损坏会在恢复时抛错，并保持全局写入屏障。
    static var hasPendingRecovery: Bool {
        do { return try journalURL.checkResourceIsReachable() }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return false }
        catch { return true }
    }

    /// 页面传入显示时的账户来源；先冻结，排空旧写入，再生成真实数据库计划。
    func remove(instanceID: String, sourceScope: NivoOAuthScope) async throws {
        guard sourceScope == NivoOAuthAccess.captureScope() else { throw CancellationError() }
        let lease = try NivoPersonalBackupAccess.beginProviderRestore(personalLeaseID: nil, allowingProviderDeletionRecovery: true)
        defer { ProviderConfigStore.shared.nmEndRestore(lease); NivoPersonalBackupAccess.endProviderRestore(lease) }
        try await perform(instanceID: instanceID, token: lease)
    }

    /// 独立凭证清理复用持久日志；成功和失败都只刷新本次租约造成的页面代次。
    /// 返回保留账户时旧意图已终结，但调用方必须显示保留提示，不能宣称已退出或清空输入。
    @discardableResult
    func clearCredentials(instanceID: String, accounts: [String], sourceScope: NivoOAuthScope,
                          onRestoreFinished: (NivoOAuthScope) -> Void = { _ in }) async throws -> NivoCredentialDeletion.Outcome {
        return try await clearCredentials(instanceID: instanceID, accounts: accounts, sourceScope: sourceScope,
            isDraft: false, onRestoreFinished: onRestoreFinished)
    }

    /// 已持久登记的未提交草稿仅清理凭证；同标识已成为实例时拒绝误删。
    @discardableResult
    func clearDraftCredentials(instanceID: String, sourceScope: NivoOAuthScope,
                               onRestoreFinished: (NivoOAuthScope) -> Void = { _ in }) async throws -> NivoCredentialDeletion.Outcome {
        return try await clearCredentials(instanceID: instanceID, accounts: NivoCredentialDeletion.accounts,
            sourceScope: sourceScope, isDraft: true, onRestoreFinished: onRestoreFinished)
    }

    private func clearCredentials(instanceID: String, accounts: [String], sourceScope: NivoOAuthScope,
                                  isDraft: Bool, onRestoreFinished: (NivoOAuthScope) -> Void) async throws -> NivoCredentialDeletion.Outcome {
        guard sourceScope == NivoOAuthAccess.captureScope() else { throw CancellationError() }
        let lease = try NivoPersonalBackupAccess.beginProviderRestore(personalLeaseID: nil, allowingProviderDeletionRecovery: true)
        let store = ProviderConfigStore.shared
        let generation = store.nmRestoreGeneration
        defer {
            store.nmEndRestore(lease)
            // 还持有账户租约时回传代次，不能把外部恢复或切号的身份借给旧页面。
            if store.nmRestoreGeneration != generation { onRestoreFinished(NivoOAuthAccess.captureScope()) }
            NivoPersonalBackupAccess.endProviderRestore(lease)
        }
        return try await perform(instanceID: instanceID, token: lease, credentialAccounts: accounts, isDraft: isDraft)
    }

    /// 已持有账户锁的退出及启动恢复不得再次申请提供商租约。
    func recoverDuringAccountChange(removing instanceID: String? = nil) async throws {
        guard NivoPersonalBackupAccess.hasAccountTransition else { throw NivoPersonalBackupError.busy }
        guard instanceID != nil || Self.hasPendingRecovery else { return }
        let token = UUID()
        defer { ProviderConfigStore.shared.nmEndRestore(token) }
        try await perform(instanceID: instanceID, token: token)
    }

    /// 失败后提供独立重试入口，即使原提供商已经不在列表中仍可继续清理。
    @discardableResult
    func retry() async throws -> NivoCredentialDeletion.Outcome {
        let lease = try NivoPersonalBackupAccess.beginProviderRestore(personalLeaseID: nil, allowingProviderDeletionRecovery: true)
        defer { ProviderConfigStore.shared.nmEndRestore(lease); NivoPersonalBackupAccess.endProviderRestore(lease) }
        return try await perform(instanceID: nil, token: lease)
    }

    @discardableResult
    private func perform(instanceID: String?, token: UUID, credentialAccounts: [String]? = nil,
                         isDraft: Bool = false) async throws -> NivoCredentialDeletion.Outcome {
        guard !isRunning, !BackupRestoreJournal.hasPendingRecovery else { throw NivoPersonalBackupError.busy }
        isRunning = true
        lastCredentialOutcome = nil
        defer { isRunning = false; needsRecovery = Self.hasPendingRecovery }
        let store = ProviderConfigStore.shared
        let transaction = NivoProviderDeletion(journalURL: Self.journalURL)
        try await store.nmBeginRestore(token, retryingFailedWrites: Self.hasPendingRecovery)
        let pending = try transaction.pending()
        if let credentialAccounts, let instanceID {
            guard (store.instance(for: instanceID) == nil) == isDraft else { throw CancellationError() }
            if let pending {
                guard pending.plan.instanceID == instanceID,
                      pending.plan.credentialAccounts.map(Set.init) == Set(credentialAccounts) else {
                    throw NivoProviderDeletion.Failure.pendingRecovery
                }
            }
        }
        let operations = NivoProviderDeletion.Operations(prepare: NivoProviderDeletionKeychain.prepare,
            containsStage: NivoProviderDeletionKeychain.contains,
            persist: { try await store.nmPersistProviderDeletion($0.plan, token: token) },
            synchronize: { try await ChatStore.shared.nmRecordProviderDeletion($0, zoneName: DeviceIdentity.zoneName) },
            cleanup: NivoProviderDeletionKeychain.cleanup,
            reload: {
                try await store.nmReloadFromDisk()
                try await store.nmReloadThinkingRuleCache()
            }, discard: NivoProviderDeletionKeychain.discard, cleanupOutcome: NivoProviderDeletionKeychain.outcome,
            settle: NivoOAuthDraftHost.shared.settleDeletion)
        var isRetryingCredentialDeletion = credentialAccounts != nil && pending != nil
        if let pending, pending.phase == .prepared, try !NivoProviderDeletionKeychain.contains(pending.identifier) {
            isRetryingCredentialDeletion = false
        }
        let recovered = try await transaction.recover(using: operations)
        if let credentialAccounts, let instanceID {
            // 恢复只继续旧快照，不能重捕获后来的凭证并扩大删除范围。
            if isRetryingCredentialDeletion { return publish(recovered) }
            let plan = NivoProviderDeletion.Plan(instanceID: instanceID, entryIDs: [], groupIDs: [],
                updatedGroupIDs: [], ruleIDs: [], deletedAt: Date(), credentialAccounts: credentialAccounts)
            return publish(try await transaction.run(plan, using: operations))
        }
        if let instanceID, let plan = try await store.nmPrepareProviderDeletion(instanceID: instanceID, token: token) {
            return publish(try await transaction.run(plan, using: operations))
        }
        return publish(recovered)
    }

    private func publish(_ outcome: NivoCredentialDeletion.Outcome) -> NivoCredentialDeletion.Outcome {
        lastCredentialOutcome = outcome
        return outcome
    }
}

/// 两种设置布局共享删除恢复提示，失败不会因原行消失而失去重试入口。
struct NivoProviderDeletionNotice: View {
    @ObservedObject private var status = NivoProviderDeletionHost.shared
    @ObservedObject private var drafts = NivoOAuthDraftHost.shared
    @State private var failure: String?
    @State private var didPreserveDuringRetry = false

    private var isWorking: Bool { status.isRunning || drafts.isRunning }
    private var hasRecovery: Bool {
        status.needsRecovery || NivoProviderDeletionHost.hasPendingRecovery || drafts.needsRecovery
    }
    private var hasPreservedCredentials: Bool {
        didPreserveDuringRetry || status.lastCredentialOutcome?.hasPreservedCredentials == true
            || drafts.lastCredentialOutcome?.hasPreservedCredentials == true
    }

    var body: some View {
        Group {
            if isWorking || hasRecovery || hasPreservedCredentials {
                VStack(alignment: .leading, spacing: 10) {
                    if isWorking { ProgressView(AppLocalized("Saving…")) }
                    else if hasRecovery {
                        Label(AppLocalized("nivo.providers.deletion.retry"), systemImage: "exclamationmark.triangle")
                        if let failure { Text(failure).font(.footnote) }
                        Button(AppLocalized("Retry")) {
                            Task {
                                do {
                                    // 草稿先消费属于自己的旧日志；通用恢复先丢日志会使后续草稿误删后来凭证。
                                    try await drafts.retry()
                                    if status.needsRecovery || NivoProviderDeletionHost.hasPendingRecovery {
                                        let outcome = try await status.retry()
                                        didPreserveDuringRetry = didPreserveDuringRetry || outcome.hasPreservedCredentials
                                    }
                                    failure = nil
                                } catch { failure = error.localizedDescription }
                            }
                        }
                    }
                    // 保留结果只显示说明，不因为提示仍可见而保留恢复屏障或旧重试按钮。
                    if hasPreservedCredentials {
                        Label(AppLocalized("nivo.providers.credentials.preserved"), systemImage: "info.circle")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .padding(16)
                .background(NanoMuseTones.surface, in: RoundedRectangle(cornerRadius: 16))
            }
        }
        // 页面重建时也读取持久草稿，失败记录不依赖原新增表单继续存活。
        .onAppear { drafts.refreshStatus() }
    }
}

extension NivoProviderDeletion.Failure: LocalizedError {
    /// 固定错误说明不泄漏日志内容、实例身份或凭证。
    var errorDescription: String? { AppLocalized("nivo.providers.deletion.retry") }
}
