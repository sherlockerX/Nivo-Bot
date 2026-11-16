import Foundation

private let logger = AppLogger(category: "Backup")

// nanoMuse: 快照全部准备并校验完成后才写入日志，正式导入只能发生在日志成功落盘之后。
/// 备份恢复的持久化边界，日志绑定本次运行及完整快照清单。
enum BackupRestoreJournal {
    private static var supportDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BackupRestore", isDirectory: true)
    }

    private static var markerURL: URL { supportDir.appendingPathComponent("in-progress.json") }
    typealias Marker = NivoBackupRecoveryState.Marker
    static var hasPendingRecovery: Bool { NivoBackupRecoveryState.read(markerURL).requiresRecovery }
    static var hasPendingPersonalDataRecovery: Bool { NivoBackupRecoveryState.read(markerURL).affectsPersonalData }
    static let fileSnapshotSidecarSuffix = NivoBackupRollbackFiles.fileSidecarSuffix
    static let absentFileSidecarSuffix = NivoBackupRollbackFiles.absentSidecarSuffix

    /// 每次导入使用独立目录，未登记的快照不能用于其他运行。
    static func stagingRoot(runId: String) -> URL {
        supportDir.appendingPathComponent("rollback-\(runId)", isDirectory: true)
    }

    /// 目录不可读必须抛错，不能当作不存在恢复材料。
    static func allStagingRoots() throws -> [URL] {
        do {
            return try FileManager.default.contentsOfDirectory(atPath: supportDir.path)
                .filter { $0 == "rollback" || $0.hasPrefix("rollback-") }
                .map { supportDir.appendingPathComponent($0, isDirectory: true) }
        } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            return []
        }
    }

    /// 持久化完整清单，只有成功返回后才能开始修改正式文件。
    static func begin(backupId: String, categories: [String], runId: String,
                      credentialRestore: NivoCredentialRestoreReceipt? = nil,
                      providerKeyRotation: NivoProviderKeyRotation.Receipt? = nil,
                      providerSetupQueue: NivoProviderSetupSyncSQL.Receipt? = nil) throws {
        guard !hasPendingRecovery else { throw NivoPersonalBackupError.busy }
        let root = stagingRoot(runId: runId)
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        _ = try NivoBackupRollbackFiles.entries(in: root, expectedNames: names)
        if let credentialRestore {
            guard categories.contains(BackupCategory.providers.rawValue) else { throw CocoaError(.fileReadCorruptFile) }
            try credentialRestore.validate()
        }
        // nanoMuse: 单提供商轮换和发送队列回执只在提供商事务内恢复。
        if providerKeyRotation != nil || providerSetupQueue != nil {
            guard categories == [BackupCategory.providers.rawValue] else { throw CocoaError(.fileReadCorruptFile) }
            try providerKeyRotation?.validate()
            try providerSetupQueue?.validate()
        }
        let marker = Marker(backupId: backupId, startedAt: Date(), categories: categories,
            runId: runId, snapshotNames: names, credentialRestore: credentialRestore,
            providerKeyRotation: providerKeyRotation, providerSetupQueue: providerSetupQueue)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(marker)
        guard data.count <= 4 * 1_024 * 1_024 else { throw CocoaError(.fileWriteOutOfSpace) }
        try data.write(to: markerURL, options: .atomic)
    }

    /// 日志先删除成功，才能删除快照；任一步失败都不能被忽略。
    static func finish(runId: String) throws {
        guard let marker = NivoBackupRecoveryState.read(markerURL).marker, marker.runId == runId else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try NivoBackupRollbackFiles.finish(marker: markerURL, root: stagingRoot(runId: runId))
        // nanoMuse: 日志先删除成功，轮换暂存才可清理；失败由下次启动清理孤立材料。
        if let receipt = marker.providerKeyRotation { try NivoProviderKeyRotationKeychain.discard(receipt.identifier) }
    }

    /// 返回可读的中断日志，损坏日志由hasPendingRecovery继续阻止使用。
    static func interrupted() -> Marker? { NivoBackupRecoveryState.read(markerURL).marker }

    /// 所有恢复动作成功后统一清日志，重复启动不会丢失尚未恢复的副本。
    @discardableResult
    static func reconcileAtLaunch() -> Marker? {
        let state = NivoBackupRecoveryState.read(markerURL)
        if case .unreadable = state {
            logger.error("[Restore] unreadable recovery journal; snapshots preserved")
            return nil
        }
        do {
            let roots = try allStagingRoots()
            guard let marker = state.marker else {
                // nanoMuse: 已明确没有日志，孤立密钥暂存清理失败不应阻止其他文件恢复。
                cleanOrphanRotationStages()
                // 没有日志表示未开始导入或已经完成，孤立快照可以清理；路径只能来自固定根目录。
                for root in roots { try FileManager.default.removeItem(at: root) }
                return nil
            }
            let root = try NivoBackupRollbackFiles.recoveryRoot(marker: marker, roots: roots)
            let entries = try NivoBackupRollbackFiles.entries(in: root, expectedNames: marker.snapshotNames)
            for entry in entries { try restore(entry) }
            // nanoMuse: 先删除本次导入的凭证，再解除恢复屏障；系统拒绝读取/删除时保留日志。
            if let credentialRestore = marker.credentialRestore { try NivoCredentialRestore.rollback(credentialRestore) }
            // nanoMuse: 恢复本次轮换和发送意图；只触及回执中仍由本次提交拥有的队列行。
            if let receipt = marker.providerKeyRotation { try NivoProviderKeyRotationKeychain.rollback(receipt) }
            if let receipt = marker.providerSetupQueue {
                let database = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("MinisChat/minis.db")
                try NivoProviderSetupSyncSQL.rollback(receipt, databaseURL: database)
            }
            try NivoBackupRollbackFiles.finish(marker: markerURL, root: root)
            // nanoMuse: 已删除日志表示回滚完成，孤立暂存清理失败不再把业务标记为未完成。
            cleanOrphanRotationStages()
            logger.info("[Restore] launch reconcile restored \(entries.count) snapshots")
            return marker
        } catch {
            logger.error("[Restore] recovery incomplete; journal and remaining snapshots preserved: \(error.localizedDescription)")
            return state.marker
        }
    }

    private static func cleanOrphanRotationStages() {
        do { try NivoProviderKeyRotationKeychain.discardOrphans(preserving: nil) }
        catch { logger.warning("[Restore] completed rotation cleanup will retry after unlock") }
    }

    private static func restore(_ entry: NivoBackupRollbackFiles.Entry) throws {
        switch entry.kind {
        case .directory: try atomicReplace(directory: entry.saved, onto: entry.live)
        case .file: try atomicReplaceFile(entry.saved, onto: entry.live)
        // nanoMuse: 数据库通过在线恢复写入原数据库，保留WAL和现有连接的一致性。
        case .sqlite: try NivoSQLiteSnapshot.restore(from: entry.saved, to: entry.live)
        case .absent:
            if FileManager.default.fileExists(atPath: entry.live.path) { try FileManager.default.removeItem(at: entry.live) }
        }
    }

    /// 文件替换只消耗同目录临时副本，正式回滚快照始终保留。
    static func atomicReplaceFile(_ saved: URL, onto live: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: live.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staged = live.deletingLastPathComponent().appendingPathComponent(".restore-file-" + UUID().uuidString)
        defer { try? manager.removeItem(at: staged) }
        try manager.copyItem(at: saved, to: staged)
        if manager.fileExists(atPath: live.path) { _ = try manager.replaceItemAt(live, withItemAt: staged) }
        else { try manager.moveItem(at: staged, to: live) }
    }

    /// 目录原子替换前移除内部标记，失败时原快照仍可再次使用。
    static func atomicReplace(directory saved: URL, onto live: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: live.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staged = live.deletingLastPathComponent().appendingPathComponent(".restore-swap-" + UUID().uuidString, isDirectory: true)
        defer { try? manager.removeItem(at: staged) }
        try manager.copyItem(at: saved, to: staged)
        try manager.removeItem(at: staged.appendingPathComponent(".live-path"))
        if manager.fileExists(atPath: live.path) { _ = try manager.replaceItemAt(live, withItemAt: staged) }
        else { try manager.moveItem(at: staged, to: live) }
    }
}
