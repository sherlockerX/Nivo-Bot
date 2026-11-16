import Foundation

/// 任务备份只携带内容和历史，不携带运行租约、结算队列或脚本授权。
struct NivoRoutineBackup: Codable, Equatable, Sendable {
    var version = 1
    var routines: [NanoMuseRoutine]
    var settings: NivoRoutineNotificationSettings
    var homePaths: [String]

    struct Merge: Sendable {
        var routines: [NanoMuseRoutine]
        var importedIDs: [String]
        var conflicts: [String]
    }

    /// 同名本机任务保持原样；新任务关闭并撤销排队请求，历史保留中断状态。
    func merging(into local: [NanoMuseRoutine]) throws -> Merge {
        try validate()
        try NivoRoutineArchive.validate(local)
        let existing = Dictionary(uniqueKeysWithValues: local.map { ($0.id, $0) })
        var merged = local
        var imported: [String] = []
        var conflicts: [String] = []
        for row in routines {
            if let previous = existing[row.id] {
                if previous != row { conflicts.append(row.label) }
                continue
            }
            var restored = NivoRoutineRunRules.recovering([row])[0]
            restored.enabled = false
            restored.pendingRun = nil
            // 专属会话由新设备首次显式运行时创建，历史中的原会话标识仍供回顾。
            restored.dedicatedSessionID = nil
            if restored.execution?.target == .newSession { restored.sessionId = nil }
            merged.append(restored)
            imported.append(restored.id)
        }
        try NivoRoutineArchive.validate(merged)
        return Merge(routines: merged, importedIDs: imported, conflicts: conflicts)
    }

    /// 备份路径只允许home内的相对节点，禁止跨目录和系统保留的回滚标记。
    static func validatePath(_ path: String) throws {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, path.utf8.count <= 4_096, components.count <= 64,
              !path.contains("\\"), !path.contains(":"), !path.contains("\0"),
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0 != ".live-path" }) else {
            throw NivoPersonalBackupError.invalidPackage
        }
    }

    /// 整包结构先验证，任何坏任务或重复路径都会在写入前失败。
    func validate() throws {
        guard version == 1, homePaths.count <= 20_000,
              Set(homePaths).count == homePaths.count else { throw NivoPersonalBackupError.invalidPackage }
        try NivoRoutineArchive.validate(routines)
        try NivoRoutineNotificationRules.validateQuietHours(settings.quietHours)
        for path in homePaths { try Self.validatePath(path) }
    }
}
