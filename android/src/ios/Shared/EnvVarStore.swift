import Foundation
import Security
import os.log

private let logger = AppLogger(category: "EnvVarStore")

// nanoMuse: 元数据值模型迁至NivoEnvVarState，便携测试直接验证应用使用的版本及文件规则。

// MARK: - EnvVarStore

@MainActor
final class EnvVarStore: ObservableObject {
    static let shared = EnvVarStore()

    @Published private(set) var entries: [EnvVarEntry] = []
    // nanoMuse: 读取失败持续显示，不能让损坏档案看起来只是没有变量。
    @Published private(set) var loadError: String?

    // nanoMuse: 后台脚本读取同一个注入路径，并与文件恢复共用进程锁。
    nonisolated private let fileURL: URL
    private var recoveryTask: Task<Void, Error>?
    nonisolated private var transaction: NivoEnvVarTransaction { NivoEnvVarTransaction(fileURL: fileURL) }
    nonisolated private static let keychainService = "io.github.nanomuse.app.envvar"

    // nanoMuse: 恢复日志明确捕获元数据位置，凭证仍只保存在Keychain。
    nonisolated static var configFileURLForBackup: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MinisChat/env-vars.json")
    }

    // nanoMuse: 可注入独立元数据文件供Apple测试使用；读取失败保留错误，不伪装空档案。
    init(fileURL: URL = EnvVarStore.configFileURLForBackup, schedulesCleanup: Bool = true) {
        self.fileURL = fileURL
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try transaction.requireSettled()
            self.entries = try NivoEnvVarState.read(fileURL)
        } catch {
            loadError = AppLocalized("Saved data could not be opened. The original file was preserved.")
            logger.error("Environment metadata could not be loaded")
        }
        if schedulesCleanup { scheduleLegacyRecordCleanupIfNeeded() }
    }

    // MARK: - Legacy whole-file record cleanup

    private static let legacyCleanupKey = "cloudSync.envVar.legacyV2RecordDeleted"

    /// One-time job that removes the old EnvVarV2 whole-file record
    /// from this device's cloud zone after the first per-variable
    /// EnvVarItem push round. Without this, the legacy record stays
    /// on iCloud forever, taking storage and confusing other devices'
    /// inbound merger.
    ///
    /// Sequencing:
    ///   1. Re-mark every local entry dirty as EnvVarItem (idempotent —
    ///      no-op if cloud already has them).
    ///   2. Queue an op=delete dirty row for EnvVarV2 (recordId
    ///      "env-vars"). SyncCore.sendNow drains the EnvVarItem
    ///      upserts in the same batch as the EnvVarV2 delete; CloudKit
    ///      orders the upserts before the delete by record id, so the
    ///      new schema is in cloud before the old record disappears.
    ///   3. Persist `legacyCleanupKey = true` so subsequent launches
    ///      skip this work.
    private func scheduleLegacyRecordCleanupIfNeeded() {
        // nanoMuse: 损坏本机档案不能触发旧云端元数据清理。
        guard loadError == nil, !UserDefaults.standard.bool(forKey: Self.legacyCleanupKey) else { return }
        let generation = NanoMuseAccountData.shared.generation
        // Defer past actor init to avoid touching ChatStore before its
        // SyncCore wiring has completed (ChatStore actor is also being
        // brought up around the same time on app launch).
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000) // 5s
            guard let self, !Task.isCancelled, self.loadError == nil,
                  NanoMuseAccountData.shared.generation == generation, !Self.hasPendingRecovery else { return }
            await MainActor.run {
                self.markAllEntriesDirty()
                Task { await ChatStore.shared.markDirty(
                    recordType: "EnvVar",
                    recordId: "env-vars",
                    operation: "delete"
                ) }
                UserDefaults.standard.set(true, forKey: Self.legacyCleanupKey)
                logger.info("[EnvVarStore] legacy EnvVarV2 cleanup scheduled (\(self.entries.count) entries re-emitted as EnvVarItem)")
            }
        }
    }

    // MARK: - Persistence (key list)

    // nanoMuse: 同步/恢复重新加载失败时保留当前列表，下一次写入仍严格读取文件。
    func reloadFromDisk() {
        do {
            // nanoMuse: 页面重开、前台恢复均重放未结束的文件/凭证操作。
            try nmRecoverFiles()
        } catch {
            loadError = AppLocalized("Saved data could not be opened. The original file was preserved.")
            logger.error("Environment metadata could not be reloaded")
        }
    }

    // nanoMuse: 恢复元数据不重复写凭证，避免清除刚插入条目的回滚所有权。
    /// 所有字段先验证，文件成功写入后才发布和计数，已有变量保持本机内容。
    func nmImportMetadata(_ incoming: [EnvVarEntry]) throws -> (imported: Int, skipped: Int) {
        // nanoMuse: 备份使用自己的回滚日志，不在其中嵌套环境变量恢复事务。
        try transaction.requireSettled()
        try NivoEnvVarState.validate(incoming)
        var candidate = try NivoEnvVarState.read(fileURL)
        var keys = Set(candidate.map(\.key))
        var identifiers = Set(candidate.map(\.id))
        var added: [EnvVarEntry] = []
        for entry in incoming {
            guard Self.isValidKey(entry.key), !entry.id.isEmpty, entry.createdAt.timeIntervalSince1970.isFinite else {
                throw CocoaError(.fileReadCorruptFile)
            }
            guard keys.insert(entry.key).inserted else { continue }
            let identifier = identifiers.insert(entry.id).inserted ? entry.id : UUID().uuidString
            added.append(EnvVarEntry(id: identifier, key: entry.key, createdAt: entry.createdAt,
                note: entry.note, updatedAt: entry.updatedAt))
        }
        candidate.append(contentsOf: added)
        try commit(candidate)
        for entry in added { markEntryDirty(entryId: entry.id) }
        return (added.count, incoming.count - added.count)
    }

    // nanoMuse: 候选文件提交后才发布列表，失败向同步屏障或表单传播。
    private func commit(_ candidate: [EnvVarEntry]) throws {
        try NivoEnvVarState.save(candidate, to: fileURL)
        entries = candidate
        loadError = nil
    }

    /// 本机表单使用返回值保留未保存输入，错误文本不包含秘密正文。
    private func performLocal(_ body: () throws -> Void) -> Bool {
        do {
            try nmRecoverFiles()
            try transaction.requireSettled()
            try NivoCloudCredentialAccess.perform(expectedGeneration: NanoMuseAccountData.shared.generation, body)
            return true
        } catch {
            if (try? transaction.pending()) != nil { loadError = AppLocalized("Could not save") }
            logger.error("Environment update was not confirmed")
            ShareFeedbackToast.show(NivoLifeModel.message(error))
            return false
        }
    }

    /// Mark a single variable's per-key sync record as dirty. Caller
    /// passes the entry's UUID (EnvVarEntry.id), which is also the
    /// EnvVarItem record's recordName.
    fileprivate func markEntryDirty(entryId: String, operation: String = "upsert") {
        Task { await ChatStore.shared.markDirty(
            recordType: "EnvVarItem",
            recordId: entryId,
            operation: operation
        ) }
    }

    /// Re-emit per-key markDirty for every current entry. Used by
    /// markAllLocalForReupload and any post-restore path that doesn't
    /// know which keys changed.
    func markAllEntriesDirty() {
        for entry in entries {
            markEntryDirty(entryId: entry.id, operation: "upsert")
        }
    }

    // MARK: - Keychain (values)

    // nanoMuse: 本机与入站凭证共用原位写入，用户保存推进原子版本。
    @discardableResult
    nonisolated private static func saveValue(_ value: String, forKey key: String) -> Bool {
        do {
            try NivoCredentialSyncKeychain.withEnvironmentLock {
                try NivoEnvVarTransaction(fileURL: configFileURLForBackup).requireSettled()
                _ = try NivoCredentialSyncKeychain.saveEnvironment(value, key: key, version: Date(), isLocal: true)
            }
            return true
        } catch { return false }
    }

    nonisolated private static func loadValue(forKey key: String) -> String? {
        // Try synchronizable first
        let syncQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: key,
            kSecAttrSynchronizable as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        if SecItemCopyMatching(syncQuery as CFDictionary, &result) == errSecSuccess,
           let data = result as? Data { return String(data: data, encoding: .utf8) }
        // Fallback to legacy non-sync
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Non-isolated read for use from CloudSyncEngine (background thread).
    nonisolated static func loadValueSync(forKey key: String) -> String? {
        loadValue(forKey: key)
    }

    /// Non-isolated write for use from CloudSyncEngine (background thread).
    nonisolated static func saveValueSync(_ value: String, forKey key: String) {
        saveValue(value, forKey: key)
    }

    // MARK: - Validation

    /// Valid env var name: starts with a letter, contains only letters, digits, and underscores.
    static let keyRegex = /^[A-Za-z][A-Za-z0-9_]*$/

    static func isValidKey(_ key: String) -> Bool {
        key.wholeMatch(of: keyRegex) != nil
    }

    // MARK: - Value Sanitization

    /// Strip invisible/control characters that iOS paste can introduce (e.g. \u{9b} CSI).
    /// Keeps only printable ASCII and common whitespace (space, tab).
    private static func sanitizeValue(_ value: String) -> String {
        String(value.unicodeScalars.filter { scalar in
            // Allow printable ASCII (0x20-0x7E) and tab (0x09)
            (scalar.value >= 0x20 && scalar.value <= 0x7E) || scalar.value == 0x09
        })
    }

    // MARK: - Public API

    // nanoMuse: 所有本机修改读取真实元数据，写入成功后才推进版本及脏记录。
    @discardableResult
    func add(key: String, value: String, note: String = "") -> Bool {
        performLocal {
            var candidate = try NivoEnvVarState.read(fileURL)
            let name = key.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            guard !candidate.contains(where: { $0.key == name }) else { throw NivoEnvVarState.Failure.duplicateKey }
            var entry = EnvVarEntry(key: name, note: note, updatedAt: Date())
            try NivoEnvVarState.validate([entry])
            entry.updatedAt = try nextCredentialVersion(key: name, proposed: entry.version)
            candidate.append(entry)
            try commitTransaction(candidate, writeKey: name, value: Self.sanitizeValue(value), notifySync: true)
        }
    }

    /// 改名先保存目标值及元数据，原凭证仅在新映射落盘后清理。
    @discardableResult
    func update(id: String, key: String, value: String, note: String? = nil) -> Bool {
        performLocal {
            var candidate = try NivoEnvVarState.read(fileURL)
            guard let index = candidate.firstIndex(where: { $0.id == id }) else { throw NivoEnvVarState.Failure.invalidRecord }
            let previous = candidate[index]
            let name = key.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            guard !candidate.contains(where: { $0.key == name && $0.id != id }) else { throw NivoEnvVarState.Failure.duplicateKey }
            candidate[index].key = name
            if let note { candidate[index].note = note }
            candidate[index].updatedAt = try NivoEnvVarState.nextVersion(after: previous.version, now: Date())
            try NivoEnvVarState.validate(candidate)
            candidate[index].updatedAt = try nextCredentialVersion(key: name, proposed: candidate[index].version)
            try commitTransaction(candidate, writeKey: name, value: Self.sanitizeValue(value), notifySync: true)
        }
    }

    /// 仅修改备注不读取或写入秘密，但使用同一真实修改时间。
    @discardableResult
    func updateNote(id: String, note: String) -> Bool {
        performLocal {
            var candidate = try NivoEnvVarState.read(fileURL)
            guard let index = candidate.firstIndex(where: { $0.id == id }) else { throw NivoEnvVarState.Failure.invalidRecord }
            candidate[index].note = note
            candidate[index].updatedAt = try NivoEnvVarState.nextVersion(after: candidate[index].version, now: Date())
            try commitTransaction(candidate, notifySync: true)
        }
    }

    /// 元数据提交后移除不再被任何变量引用的凭证；失败不先清空用户列表。
    @discardableResult
    func delete(id: String) -> Bool {
        performLocal {
            let current = try NivoEnvVarState.read(fileURL)
            guard current.contains(where: { $0.id == id }) else { return }
            let candidate = current.filter { $0.id != id }
            try commitTransaction(candidate, notifySync: true)
        }
    }

    func value(forKey key: String) -> String? {
        // nanoMuse: 未结束的事务不让表单读到新值与旧名称的组合。
        try? NivoCredentialSyncKeychain.withEnvironmentLock {
            try transaction.requireSettled()
            return try NivoCredentialSyncKeychain.environmentValue(key: key)
        }
    }

    func entry(id: String) -> EnvVarEntry? {
        entries.first(where: { $0.id == id })
    }

    // nanoMuse: 同步不能把启动时读取失败的空界面缓存当成记录已删除。
    func nmEntryForSync(id: String) throws -> EnvVarEntry? {
        try transaction.requireSettled()
        return try NivoEnvVarState.read(fileURL).first { $0.id == id }
    }

    /// 旧整包仅补缺少的记录，已有记录只有明确更高版本才更新。
    func nmMergeLegacyMetadata(_ remote: [EnvVarEntry], secretsJSON: String? = nil) throws {
        try NivoEnvVarState.validate(remote)
        let payload = secretsJSON.flatMap { $0.isEmpty ? nil : $0 } ?? "[]"
        let secrets = try NivoCredentialSync.environments(payload)
        guard Set(secrets.map(\.owner)).isSubset(of: Set(remote.map(\.key))) else {
            throw NivoEnvVarState.Failure.invalidRecord
        }
        let values = Dictionary(uniqueKeysWithValues: secrets.map { ($0.owner, String(decoding: $0.value, as: UTF8.self)) })
        for entry in remote {
            try nmMergeLegacyEntry(entry, value: values[entry.key])
        }
    }

    /// 旧协议只补真正缺失的值，先存在的凭证及较新本机元数据均保留。
    private func nmMergeLegacyEntry(_ entry: EnvVarEntry, value: String?) throws {
        try nmRecoverFiles()
        try transaction.requireSettled()
        let current = try NivoEnvVarState.read(fileURL)
        let local = current.first { $0.id == entry.id }
        let existingValue = try NivoCredentialSyncKeychain.environmentValue(key: entry.key)
        let missingValue = existingValue == nil ? value : nil
        if let local, entry.updatedAt == nil || entry.version <= local.version {
            guard local.key == entry.key, let missingValue else { return }
            try commitTransaction(current, writeKey: entry.key, value: missingValue, notifySync: false)
        } else {
            try applyRemoteItem(id: entry.id, key: entry.key, value: existingValue ?? value, note: entry.note,
                createdAt: entry.createdAt, updatedAt: entry.version)
        }
    }

    // MARK: - Sync inbound (per-variable)

    // nanoMuse: 单变量值、元数据、版本均需真实保存，错误返回接收屏障供重放。
    /// 旧版未提供值时保留现有凭证；改名迁移成功后才清理旧名称。
    func applyRemoteItem(id: String, key: String, value: String?, note: String,
                         createdAt: Date, updatedAt: Date) throws {
        // nanoMuse: 相同入站记录重放前先完成上一次部分写入。
        try nmRecoverFiles()
        try transaction.requireSettled()
        let current = try NivoEnvVarState.read(fileURL)
        let incoming = EnvVarEntry(id: id, key: key, createdAt: createdAt, note: note, updatedAt: updatedAt)
        guard let candidate = try NivoEnvVarState.merging(incoming, into: current) else { return }
        let previous = current.first { $0.id == id }
        var incomingValue = value
        if incomingValue == nil, let previous, previous.key != key {
            incomingValue = try NivoCredentialSyncKeychain.environmentValue(key: previous.key)
        }
        try commitTransaction(candidate, writeKey: incomingValue == nil ? nil : key, value: incomingValue, notifySync: false)
    }

    /// 远端删除不回发删除请求；元数据写盘失败不能被报告为完成。
    func applyRemoteDeletion(id: String) throws {
        // nanoMuse: 即使元数据里已没有此条目，仍先重试旧凭证清理。
        try nmRecoverFiles()
        try transaction.requireSettled()
        let current = try NivoEnvVarState.read(fileURL)
        guard current.contains(where: { $0.id == id }) else { return }
        let candidate = current.filter { $0.id != id }
        try commitTransaction(candidate, notifySync: false)
    }

    /// Returns all env vars as a dictionary for injection into shell execution.
    // nanoMuse: 脚本不能把恢复或锁屏错误当作空配置继续执行。
    nonisolated func allAsDict() throws -> [String: String] {
        try NivoCredentialSyncKeychain.withEnvironmentLock {
            try transaction.requireSettled()
            var values: [String: String] = [:]
            for entry in try NivoEnvVarState.read(fileURL) {
                if let value = try NivoCredentialSyncKeychain.environmentValue(key: entry.key) {
                    values[entry.key] = value
                }
            }
            return values
        }
    }

    // nanoMuse: 跨存储事务、恢复和同步队列确认共用此入口；日志完成前不开始下一笔编辑。
    /// 当前设备的配置是全局设置，不随nanoMuse账户目录移动。
    nonisolated static var hasPendingRecovery: Bool {
        do { return try NivoEnvVarTransaction(fileURL: configFileURLForBackup).pending() != nil }
        catch { return true }
    }

    /// 启动时在备份回滚之后调用，确认本地同步队列落盘后才解除全局恢复门禁。
    func nmRecoverPending() async throws {
        if let recoveryTask { try await recoveryTask.value; return }
        try nmRecoverFiles()
        if let recoveryTask { try await recoveryTask.value }
        try transaction.requireSettled()
    }

    /// 同步重试可触发上一笔恢复；队列尚未确认时仍暂停当前请求。
    func nmRetryRecoveryIfNeeded() throws {
        if try transaction.pending() != nil {
            guard !NivoPersonalBackupAccess.isBusy else { throw NivoPersonalBackupError.busy }
            try nmRecoverFiles()
            try transaction.requireSettled()
        }
    }

    /// 备份的元数据快照必须来自文件，不使用可能已经过期的界面缓存。
    func nmMetadataSnapshot() throws -> [EnvVarEntry] {
        try transaction.requireSettled()
        return try NivoEnvVarState.read(fileURL)
    }

    /// 旧整包协议同样从一个受锁保护的文件及Keychain快照构建，不把读取错误序列化为空值。
    func nmLegacySyncSnapshot() throws -> (metadata: String, secrets: String) {
        try NivoCredentialSyncKeychain.withEnvironmentLock {
            try transaction.requireSettled()
            let entries = try NivoEnvVarState.read(fileURL)
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            let metadata = String(decoding: try encoder.encode(entries), as: UTF8.self)
            var secrets: [[String: String]] = []
            for entry in entries {
                if let value = try NivoCredentialSyncKeychain.environmentValue(key: entry.key), !value.isEmpty {
                    secrets.append(["key": entry.key, "value": Data(value.utf8).base64EncodedString()])
                }
            }
            return (metadata, String(decoding: try encoder.encode(secrets), as: UTF8.self))
        }
    }

    private func nextCredentialVersion(key: String, proposed: Date) throws -> Date {
        let current = try NivoCredentialSyncKeychain.environmentSnapshot(key: key)?.version ?? .distantPast
        return try NivoEnvVarState.nextVersion(after: current, now: proposed)
    }

    private func commitTransaction(_ candidate: [EnvVarEntry], writeKey: String? = nil,
                                   value: String? = nil, notifySync: Bool) throws {
        let receipt = try NivoCredentialSyncKeychain.withEnvironmentLock {
            try transaction.run(after: candidate, writeKey: writeKey, notifySync: notifySync,
                prepare: { try NivoEnvVarKeychainTransaction.prepare($0, value: value) },
                using: NivoEnvVarKeychainTransaction.credentials)
        }
        entries = candidate
        loadError = nil
        if let receipt { scheduleRecoveryAcknowledgement(receipt) }
    }

    private func nmRecoverFiles() throws {
        // 整包回滚可以重载自己的元数据快照，但不能在回滚期间重放另一笔凭证事务。
        let receipt: NivoEnvVarTransaction.Journal? = try NivoCredentialSyncKeychain.withEnvironmentLock {
            guard try transaction.pending() != nil else { return nil }
            guard !BackupRestoreJournal.hasPendingRecovery, !NivoPersonalBackupAccess.isBusy else {
                throw NivoPersonalBackupError.busy
            }
            return try transaction.recover(using: NivoEnvVarKeychainTransaction.credentials)
        }
        entries = try NivoEnvVarState.read(fileURL)
        loadError = nil
        if let receipt { scheduleRecoveryAcknowledgement(receipt) }
    }

    private func scheduleRecoveryAcknowledgement(_ receipt: NivoEnvVarTransaction.Journal) {
        guard recoveryTask == nil else { return }
        recoveryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.recoveryTask = nil }
            do {
                try await ChatStore.shared.nmRecordEnvironmentChanges(receipt, zoneName: DeviceIdentity.zoneName)
                try self.transaction.finish(identifier: receipt.identifier)
                self.entries = try NivoEnvVarState.read(self.fileURL)
                self.loadError = nil
            } catch {
                self.loadError = AppLocalized("Could not save")
                throw error
            }
        }
    }
}
