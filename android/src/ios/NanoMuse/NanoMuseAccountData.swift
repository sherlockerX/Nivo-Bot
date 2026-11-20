//
//  NanoMuseAccountData.swift
//  nanoMuse — contract C12 (0.1.40): what of this phone is the signed-in account's, and what
//  happens to it when the account leaves. The table is in docs/sync.md.
//
//  - Chats are rows in upstream's store; each has an owner here (`nanomuse-owners.json`): the
//    key of the account that was signed in when the session was first seen, or "" for one made
//    while nobody was. The lists, the search, the Chat tab and the sync engine show the current
//    owner's and no others (`shows`). Pre-0.1.40 sessions are claimed the same way the first
//    time the updated app runs.
//  - The agent's memory of the person (SOUL.md, USER.md, GLOBAL.md), the feed, the goals, the
//    routines, the face, the shared workspace and the account's few UserDefaults keys sit at
//    their fixed paths while the account is signed in, so upstream reads them where it always
//    did. When the account leaves they are put aside under `nanomuse/accounts/<hash>/` (*Keep
//    this account's chats on this device*) or deleted; the next account's come back from its own
//    folder or start empty. Signed out, the phone's own set (`_local`) is in place.
//  - Settings (providers and their keys, appearance, the hub's device identity) are the
//    phone's and never move. The relay's key is saved on this device only (not iCloud Keychain).
//

import CryptoKit
import Combine
import Foundation
import Security

@MainActor
final class NanoMuseAccountData: ObservableObject {
    static let shared = NanoMuseAccountData()

    /// The owner of what was made with nobody signed in.
    nonisolated static let local = ""

    private struct Owners: Codable {
        var owners: [String: String] = [:]
    }

    private enum Keys {
        /// Set on the first launch of 0.1.40 or later; its absence with no data is a fresh install.
        static let installed = "nanomuse.installed"
    }

    /// The UserDefaults keys that are the account's rather than the phone's, by prefix.
    nonisolated static let prefPrefixes = ["nanomuse.main_chat.", "nanomuse.first_conversation.", "nanomuse.feed."]

    /// The relay's error code for a key whose account no longer exists (relay 0.1.40).
    nonisolated static let accountDeleted = "account_deleted"

    /// What becomes of the account's data when the relay refuses its key — a 401 nobody on
    /// this phone asked for (signed out from another device, a relay reset, a relay bug).
    /// Kept: put aside as *Keep this account's chats on this device* would, for the next
    /// sign-in with the same account. Only when the relay says the account itself is gone
    /// (`accountDeleted`) is there nothing to come back to, and the data goes as *Delete the
    /// account* would.
    nonisolated static func keepOnRefusedKey(code: String?) -> Bool {
        code != accountDeleted
    }

    private var owners: [String: String] = [:]
    private var loaded = false
    private var startupTask: Task<Void, Never>?
    /// 同一账户退出后再进入也有不同代次，后台任务不能凭账户名称复活。
    private(set) var generation: UInt64 = 0
    @Published private(set) var isChangingAccount = true
    @Published private(set) var isReady = false
    @Published private(set) var recoveryError: String?
    private var isRecovering = false

    private init() {}

    // MARK: - The key

    /// The key the signed-in account's data is filed under — the same the sync tables use
    /// (`NanoMuseSync.accountKey`): the relay's opaque `account.id`; "" while signed out.
    var current: String {
        NivoLocalModeHost.owner
    }

    /// The folder an account's put-aside files live under: a hash, so neither the id nor a
    /// hint (which may be the address) is ever a directory name.
    nonisolated static func dirName(_ account: String) -> String {
        if account.isEmpty { return "_local" }
        let digest = SHA256.hash(data: Data(account.utf8))
        return String(digest.map { String(format: "%02x", $0) }.joined().prefix(16))
    }

    // MARK: - Lifecycle

    /// Once, from the app root: the reinstall sweep, the relay key kept on this device, and every
    /// session given an owner.
    func start() async {
        if let startupTask { await startupTask.value; return }
        let task = Task { await recoverAtLaunch() }
        startupTask = task
        await task.value
    }

    /// 启动恢复先于同步、页面和仓库载入；失败时保留日志并给出重试入口。
    func recoverAtLaunch() async {
        guard !isRecovering else { return }
        isRecovering = true
        await NivoPersonalBackupAccess.beginAccountChange()
        defer { isRecovering = false; NivoPersonalBackupAccess.endAccountChange() }
        isChangingAccount = true
        recoveryError = nil
        do {
            try await recoverPendingSwitch()
            // nanoMuse: 应用和快捷指令都先恢复备份，再加载账户仓库和任务；失败保持恢复入口。
            let restoresProviders = BackupRestoreJournal.interrupted()?.categories.contains(BackupCategory.providers.rawValue) == true
            if restoresProviders { try await ProviderConfigStore.shared.nmWaitForConfigurationWrites(ignoringWriteFailure: true) }
            BackupRestoreJournal.reconcileAtLaunch()
            guard !BackupRestoreJournal.hasPendingRecovery else { throw NivoLifeError.corruptStore }
            // nanoMuse: 在线恢复数据库后同步重载缓存，清除导致回滚的旧镜像错误。
            if restoresProviders {
                try await ProviderConfigStore.shared.nmReloadFromDisk()
                try await ProviderConfigStore.shared.nmReloadThinkingRuleCache()
                ProviderConfigStore.shared.nmDidRollbackConfiguration()
            }
            try await NivoProviderDeletionHost.shared.recoverDuringAccountChange()
            // nanoMuse: 已持有账户锁时先结束提供商删除屏障，再重放环境变量，避免两份日志互相阻塞。
            try await EnvVarStore.shared.nmRecoverPending()
            // 默认资料只能在旧目录已合并之后写入；任何文件操作失败都由启动门禁提供重试。
            let storageLayout = NivoStoragePaths.layout
            try await Task.detached(priority: .userInitiated) {
                try NivoLegacyStorageMigration.migrate(layout: storageLayout)
            }.value
            // 仅重放上一轮本地模式迁移持有的快照，随后仍严格验证所有配置写入与载入。
            try await ProviderConfigStore.shared.nmReplayPendingLocalModeRetirement()
            // 首次安装清理不能依据启动时的JSON镜像，必须等待权威SQLite配置载入。
            try await ProviderConfigStore.shared.nmWaitForMigrationBaseline(retryingFailedWrites: false)
            await sweepIfFreshInstall()
            // 先完成旧事务，再验证本机凭证副本；失败保留来源并允许下次启动重试。
            try await NivoLocalKeychainMigration.migrateDuringStartup()
            try await NivoLocalModeHost.prepareDuringStartup()
            try await reconcileForSwitch(as: current)
            // 账户资料恢复后再播种，既保护旧SOUL，也避免SkillStore初始化抢先安装技能。
            for name in ["memory", "skills", "shared"] {
                try FileManager.default.createDirectory(
                    at: NivoStoragePaths.layout.applicationFiles.appendingPathComponent(name, isDirectory: true),
                    withIntermediateDirectories: true
                )
            }
            SoulStore.ensureExists()
            SoulStore.refreshCache()
            NanoMusePreset.apply()
            isReady = true
            isChangingAccount = false
            await reloadAfterSwitch()
            await NivoAvatarWardrobe.shared.reload()
        } catch {
            recoveryError = error.localizedDescription
        }
    }

    // MARK: - Whose chat

    func owner(of sessionId: String) -> String? {
        load()
        return owners[sessionId]
    }

    /// Whether the lists show this session right now: the current owner's, or one not claimed yet.
    func shows(_ sessionId: String) -> Bool {
        let owner = owner(of: sessionId)
        return owner == nil || owner == current
    }

    /// A chat made now belongs to whoever is signed in now (the hook in `ChatStore.createSession`).
    func claim(_ sessionId: String) {
        load()
        guard owners[sessionId] == nil else { return }
        owners[sessionId] = current
        save()
    }

    /// 为跨异步创建的对话显式认领账户，落盘失败不更新内存，不覆盖其他账户的归属。
    func claim(_ sessionId: String, owner: String) throws {
        guard !sessionId.isEmpty else { throw NivoLifeError.invalidField("conversation_id") }
        let url = Self.fileURL
        var candidate: [String: String] = [:]
        if FileManager.default.fileExists(atPath: url.path) {
            candidate = try JSONDecoder().decode(Owners.self, from: Data(contentsOf: url)).owners
        }
        if let existing = candidate[sessionId] {
            guard existing == owner else { throw NivoLifeError.accountChanged }
            owners = candidate
            loaded = true
            return
        }
        candidate[sessionId] = owner
        let data = try JSONEncoder().encode(Owners(owners: candidate))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        owners = candidate
        loaded = true
    }

    /// The sessions owned by `account`.
    func sessions(of account: String) -> [String] {
        load()
        return owners.filter { $0.value == account }.map(\.key)
    }

    /// Every session has an owner after this: one with no row goes to the account whose sync
    /// table maps it (the C10 rule), else to `account`; rows of sessions that no longer exist go.
    @discardableResult
    func reconcile(as account: String? = nil) async -> Bool {
        load()
        let previous = owners
        do {
            try await reconcileForSwitch(as: account ?? self.current)
            let changed = previous != owners
            if changed { NotificationCenter.default.post(name: .sessionDidUpdate, object: nil) }
            return changed
        } catch {
            recoveryError = NivoLifeModel.message(error)
            return false
        }
    }

    // MARK: - Leaving and entering

    /// 有活动对话或未恢复事务时拒绝切换，避免脚本还在写入被归档的共享目录。
    func requireSwitchAccess() throws {
        guard !isChangingAccount, isReady else { throw NivoLifeError.accountChanged }
        // nanoMuse: 失败回滚仍引用当前路径，不能将半恢复资料移动进其他账户。
        guard !BackupRestoreJournal.hasPendingRecovery, !NivoProviderDeletionHost.hasPendingRecovery else { throw NivoLifeError.corruptStore }
        guard SessionActivityTracker.shared.resolvedActiveSessionIds.isEmpty, !NivoCoachArchiveWrites.isBusy,
              !NanoMuseSync.shared.syncing, !NivoCloudInboundCheckpoint.shared.isBusy,
              NanoMuseScheduler.shared.running.isEmpty,
              !NanoMuseCallSession.isActive, !NivoScheduledRunScopes.shared.isBusy else {
            throw NanoMuseCloud.CloudError(code: "account_busy",
                message: AppLocalized("Wait for conversations and sync to finish before switching accounts."), status: 0)
        }
    }

    /// 文件与偏好安装后才写入身份，任何早期失败都恢复原账户；删除在提交后进行。
    func switchAccount(to target: String, keepSource: Bool, identity: NivoAccountSwitchIdentity,
                       commitIdentity: () throws -> Void) async throws {
        try requireSwitchAccess()
        let source = current
        try identity.validate(owner: target)
        // 同一账户重新登录也撤销旧授权，不能只依赖账户名称是否改变。
        NivoOAuthAccess.invalidateAll()
        guard source != target else {
            try commitIdentity()
            try await ProviderConfigStore.shared.nmFlushAccountConfiguration(instanceID: identity.instanceID,
                removedInstanceID: identity.instanceID == nil ? identity.previousInstanceID : nil)
            return
        }
        generation &+= 1
        isChangingAccount = true
        recoveryError = nil
        NanoMuseHub.shared.stop()
        NanoMuseHeadless.cancelForAccountChange()
        await NanoMuseScheduler.shared.prepareAccountChange()
        NanoMuseAvatarStudioModel.shared.invalidateForAccountChange()
        NanoMuseAvatarFlow.shared.invalidateForAccountChange()
        NanoMuseAvatarMotion.shared.cancel()
        await NivoAvatarWardrobe.shared.prepareAccountChange()
        let files = Self.transactionFiles
        do {
            try await NivoLifeModel.shared.prepareAccountSwitch()
            try await reconcileForSwitch(as: source)
            let preferences = try Self.currentPreferences()
            let metadata = try JSONEncoder().encode(identity)
            let restored = try await Task.detached {
                _ = try files.prepare(source: source, target: target, keepSource: keepSource,
                    sourceDefaults: preferences, targetIdentity: metadata)
                try files.installTarget()
                return try files.defaults(useTarget: true)
            }.value
            try Self.restorePreferences(restored)
            try commitIdentity()
            try await completeSwitch(files: files)
        } catch {
            do {
                if try await rollbackUncommitted(files: files) {
                    isChangingAccount = false
                    await reloadAfterSwitch()
                } else {
                    recoveryError = error.localizedDescription
                }
            } catch {
                recoveryError = error.localizedDescription
            }
            throw error
        }
        isChangingAccount = false
        await reloadAfterSwitch()
    }

    /// 密钥已经改变时只向前恢复，不能把旧文件配给刚登录的新身份。
    private func rollbackUncommitted(files: NivoAccountFileTransaction) async throws -> Bool {
        guard let journal = try files.load() else { return true }
        let saved = try JSONDecoder().decode(NivoAccountSwitchIdentity.self, from: journal.targetIdentity)
        if try journal.hasCommittedIdentity || saved.isApplied() { return false }
        let restored = try await Task.detached {
            _ = try files.recoverFiles(useTarget: false)
            return try files.defaults(useTarget: false)
        }.value
        try Self.restorePreferences(restored)
        try await Task.detached { try files.finish() }.value
        return true
    }

    private func completeSwitch(files: NivoAccountFileTransaction) async throws {
        try await Task.detached { try files.markCommitted(); try files.settleArchive() }.value
        guard let journal = try files.load() else { throw NivoLifeError.corruptStore }
        let identity = try JSONDecoder().decode(NivoAccountSwitchIdentity.self, from: journal.targetIdentity)
        try await ProviderConfigStore.shared.nmFlushAccountConfiguration(instanceID: identity.instanceID,
            removedInstanceID: identity.instanceID == nil ? identity.previousInstanceID : nil)
        if !journal.keepSource {
            try await NivoLifeModel.shared.discardAccount(journal.sourceOwner)
            try await deleteChats(of: journal.sourceOwner)
        }
        try await reconcileForSwitch(as: journal.targetOwner)
        try await Task.detached { try files.finish() }.value
    }

    private func recoverPendingSwitch() async throws {
        let files = Self.transactionFiles
        guard let journal = try files.load() else { return }
        let identity = try JSONDecoder().decode(NivoAccountSwitchIdentity.self, from: journal.targetIdentity)
        try identity.validate(owner: journal.targetOwner)
        if journal.isFinalizing {
            if journal.hasCommittedIdentity {
                try NanoMuseCloud.restoreTransitionIdentity(identity)
                try await ProviderConfigStore.shared.nmFlushAccountConfiguration(instanceID: identity.instanceID,
                    removedInstanceID: identity.instanceID == nil ? identity.previousInstanceID : nil)
            }
            try await Task.detached { try files.finish() }.value
            return
        }
        let committed = try journal.hasCommittedIdentity || identity.isApplied()
        let preferences = try await Task.detached {
            _ = try files.recoverFiles(useTarget: committed)
            return try files.defaults(useTarget: committed)
        }.value
        try Self.restorePreferences(preferences)
        if committed {
            try NanoMuseCloud.restoreTransitionIdentity(identity)
            try await completeSwitch(files: files)
        } else {
            try await Task.detached { try files.finish() }.value
        }
    }

    private func reloadAfterSwitch() async {
        NanoMuseScheduler.shared.reload()
        reloadStores()
        await NivoLifeModel.shared.enter()
        await NivoAvatarWardrobe.shared.reload()
        NotificationCenter.default.post(name: .nanoMuseAccountSwitched, object: current)
        NotificationCenter.default.post(name: .sessionDidUpdate, object: nil)
        NanoMuseSync.shared.accountChanged()
        NanoMuseFeedFlow.retireLegacyRoutine()
    }

    private static var transactionFiles: NivoAccountFileTransaction {
        NivoAccountFileTransaction(root: NanoMuseDirs.root, slots: accountPaths.map { .init(name: $0.0, live: $0.1) })
    }

    private static func currentPreferences() throws -> Data {
        let mine = UserDefaults.standard.dictionaryRepresentation().filter { Self.isAccountPref($0.key) }
        return try PropertyListSerialization.data(fromPropertyList: mine, format: .binary, options: 0)
    }

    private static func restorePreferences(_ data: Data) throws {
        guard let saved = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            throw NivoLifeError.corruptStore
        }
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys where isAccountPref(key) { defaults.removeObject(forKey: key) }
        for (key, value) in saved where isAccountPref(key) { defaults.set(value, forKey: key) }
        guard defaults.synchronize() else { throw CocoaError(.fileWriteUnknown) }
    }

    /// Whether something was put aside for `account`.
    nonisolated static func hasKept(_ account: String) -> Bool {
        FileManager.default.fileExists(atPath: stash(for: account).path)
    }

    nonisolated static func isAccountPref(_ key: String) -> Bool {
        prefPrefixes.contains { key.hasPrefix($0) }
    }

    // MARK: - Reinstall

    /// A reinstall keeps the Keychain: the items of ours that are this device's only (the
    /// relay's key, OAuth tokens, environment variables) would outlive the data that used them.
    /// On a launch with no marker and nothing on the phone — no provider, no chat — they go.
    /// Items shared through iCloud Keychain are the person's other devices' and are left alone.
    private func sweepIfFreshInstall() async {
        let defaults = UserDefaults.standard
        defer { defaults.set(true, forKey: Keys.installed) }
        guard !defaults.bool(forKey: Keys.installed) else { return }
        let hasProviders = !ProviderConfigStore.shared.instances.isEmpty
        let hasSessions = !(await ChatStore.shared.listSessions()).isEmpty
        guard !hasProviders, !hasSessions, NanoMuseCloud.instance == nil else { return }
        Self.sweepDeviceKeychain()
    }

    nonisolated private static func sweepDeviceKeychain() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let items = result as? [[String: Any]] else { return }
        var removed = 0
        for item in items {
            guard let service = item[kSecAttrService as String] as? String, service.hasPrefix("io.github.nanomuse.app."),
                  service != "io.github.nanomuse.app.device" else { continue }
            var delete: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
            ]
            if let account = item[kSecAttrAccount as String] as? String { delete[kSecAttrAccount as String] = account }
            if SecItemDelete(delete as CFDictionary) == errSecSuccess { removed += 1 }
        }
        AppLogger(category: "NanoMuseAccountData").info("fresh install: \(removed) device keychain item(s) of a previous install removed")
    }

    /// The relay's key is this phone's alone: saved without iCloud Keychain, unlocked after the
    /// first unlock, on this device only. `ProviderKeychainHelper.loadAPIKey` reads it as the
    /// legacy entry. Called after every sign-in and once at start (the 0.1.39 entry moves).
    static func keepRelayKeyOnThisDevice() throws {
        guard let inst = NanoMuseCloud.instance else { return }
        // 新本机条目优先，旧同步条目清理失败后不能在下次启动覆盖刚更新的密钥。
        if try readRelayKey(instanceId: inst.id) != nil {
            try removeSyncedRelayKey(instanceId: inst.id)
            return
        }
        let service = "io.github.nanomuse.app.provider.\(inst.id)"
        let syncQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "api-key",
            kSecAttrSynchronizable as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(syncQuery as CFDictionary, &result)
        if status == errSecItemNotFound { return }
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        guard let data = result as? Data, let key = String(data: data, encoding: .utf8), !key.isEmpty else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try saveRelayKeyChecked(key, instanceId: inst.id)
    }

    /// 先更新本机条目，成功后才清理旧同步条目，写入失败保留原密钥并中止切换。
    nonisolated static func saveRelayKeyChecked(_ key: String, instanceId: String) throws {
        let service = "io.github.nanomuse.app.provider.\(instanceId)"
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "api-key",
            kSecAttrSynchronizable as String: false,
        ]
        let attributes: [String: Any] = [kSecValueData as String: Data(key.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(base as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(base.merging(attributes) { _, fresh in fresh } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        try removeSyncedRelayKey(instanceId: instanceId)
        ProviderKeychainHelper.stampAPIKeySavedAt(Date(), instanceId: instanceId)
    }

    /// 上游读取器优先读取同步条目，清理必须成功才能保证请求使用新本机密钥。
    nonisolated static func removeSyncedRelayKey(instanceId: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "io.github.nanomuse.app.provider.\(instanceId)",
            kSecAttrAccount as String: "api-key", kSecAttrSynchronizable as String: true]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        ProviderKeychainHelper.nmDeviceKeyChanged(instanceId: instanceId)
    }

    /// 仅不存在返回nil，设备锁定和Keychain不可读属于恢复错误。
    nonisolated static func readRelayKey(instanceId: String) throws -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "io.github.nanomuse.app.provider.\(instanceId)",
            kSecAttrAccount as String: "api-key", kSecAttrSynchronizable as String: false,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8), !value.isEmpty else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return value
    }

    // MARK: - Internals

    /// What belongs to the account, by the name it is filed under when put aside.
    nonisolated private static var accountPaths: [(String, URL)] {
        [
            ("memory", NanoMuseDirs.memory),
            ("shared", AIChatViewModel.minisSharedPersistentDir),
            ("feed", NanoMuseDirs.root.appendingPathComponent("feed", isDirectory: true)),
            ("feed-preferences.md", NanoMuseDirs.root.appendingPathComponent("feed-preferences.md")),
            ("goals.json", NanoMuseDirs.root.appendingPathComponent("goals.json")),
            ("routines.json", NanoMuseDirs.root.appendingPathComponent("routines.json")),
            ("routine-settings.json", NanoMuseDirs.root.appendingPathComponent("routine-settings.json")),
            ("routine-settlements", NanoMuseDirs.root.appendingPathComponent("routine-settlements", isDirectory: true)),
            ("routine-home", NivoScheduledHome.directory),
            ("routine-script-approvals.json", NanoMuseDirs.root.appendingPathComponent("routine-script-approvals.json")),
            ("avatar", NanoMuseFaceStore.directory),
        ]
    }

    nonisolated private static func stash(for account: String) -> URL {
        NanoMuseDirs.root.appendingPathComponent("accounts", isDirectory: true).appendingPathComponent(dirName(account), isDirectory: true)
    }

    private func deleteChats(of account: String) async throws {
        var candidate = try readOwnersForSwitch()
        let ids = candidate.filter { $0.value == account }.map(\.key)
        // 账户退出已持有全局冻结，数据库失败时保留中继归属以便重试。
        try await ChatStore.shared.nmDeleteSessions(Set(ids))
        try NanoMuseSync.shared.dropTable(for: account)
        let remaining = try await ChatStore.shared.nmAccountSessionIDs()
        guard Set(ids).isDisjoint(with: remaining) else { throw CocoaError(.fileWriteUnknown) }
        for id in ids { candidate.removeValue(forKey: id) }
        try JSONEncoder().encode(Owners(owners: candidate)).write(to: Self.fileURL, options: .atomic)
        owners = candidate
        if !ids.isEmpty {
            AppLogger(category: "NanoMuseAccountData").info("removed \(ids.count) chat(s) of the account that left")
            NotificationCenter.default.post(name: .sessionDidUpdate, object: nil)
        }
    }

    /// 迁移边界严格读取并提交归属，损坏文件或数据库不可读都保留原档案。
    private func reconcileForSwitch(as account: String) async throws {
        let capturedGeneration = generation
        var candidate = try readOwnersForSwitch()
        let live = try await ChatStore.shared.nmAccountSessionIDs()
        guard generation == capturedGeneration else { throw NivoLifeError.accountChanged }
        for identifier in live where candidate[identifier] == nil {
            candidate[identifier] = try NanoMuseSync.shared.ownerChecked(of: identifier) ?? account
        }
        candidate = candidate.filter { live.contains($0.key) }
        try FileManager.default.createDirectory(at: Self.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(Owners(owners: candidate)).write(to: Self.fileURL, options: .atomic)
        owners = candidate
        loaded = true
    }

    private func readOwnersForSwitch() throws -> [String: String] {
        guard FileManager.default.fileExists(atPath: Self.fileURL.path) else { return [:] }
        return try JSONDecoder().decode(Owners.self, from: Data(contentsOf: Self.fileURL)).owners
    }

    private func reloadStores() {
        NanoMuseFeedStore.shared.reload()
        NanoMuseGrowthStore.shared.reload()
        NanoMuseFeedStatus.shared.failure = nil
        NanoMuseGoalStore.shared.reload()
        NanoMuseFaceStore.shared.reload()
        NanoMuseOwnClip.shared.rescan()
        SoulStore.refreshCache()
    }

    // MARK: - Persistence

    private static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        return dir.appendingPathComponent("nanomuse-owners.json")
    }

    private func load() {
        guard !loaded else { return }
        let url = Self.fileURL
        if let data = try? Data(contentsOf: url) {
            if let saved = try? JSONDecoder().decode(Owners.self, from: data) { owners = saved.owners }
        } else if FileManager.default.fileExists(atPath: url.path) {
            // The file is there but could not be read (the phone is locked, the app woke in the
            // background): keep it, and read again on the next call rather than start empty and
            // write that over it.
            return
        }
        loaded = true
    }

    private func save() {
        guard loaded, let data = try? JSONEncoder().encode(Owners(owners: owners)) else { return }
        try? data.write(to: Self.fileURL, options: .atomic)
    }
}
