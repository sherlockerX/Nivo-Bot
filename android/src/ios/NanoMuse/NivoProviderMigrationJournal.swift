import Foundation

/// 旧提供商迁移的非秘密记录，仅固定身份和阶段，不保存凭证或摘要。
struct NivoProviderMigrationPlan: Codable, Equatable {
    enum Slot: String, Codable, CaseIterable {
        case anthropicAPI, anthropicOAuth, geminiAPI, geminiOAuth, openAIAPI, openAIOAuth
    }
    enum Phase: String, Codable { case prepared, configurationSaved, completed }

    var schema = 1
    var targets: [String: String]
    var primaryGroupID = UUID().uuidString
    var subGroupID = UUID().uuidString
    var createdAt = Date()
    var phase: Phase = .prepared

    /// 拒绝损坏及未知版本，不用一个新计划覆盖尚未完成的旧记录。
    func validate() throws {
        guard schema == 1, targets.count <= Slot.allCases.count,
              Set(targets.values).count == targets.count,
              UUID(uuidString: primaryGroupID) != nil, UUID(uuidString: subGroupID) != nil,
              primaryGroupID != subGroupID, createdAt.timeIntervalSince1970.isFinite else {
            throw CocoaError(.fileReadCorruptFile)
        }
        for (slot, identifier) in targets {
            guard Slot(rawValue: slot) != nil, !identifier.isEmpty, identifier.utf8.count <= 512,
                  !identifier.contains("\0") else { throw CocoaError(.fileReadCorruptFile) }
        }
    }
}

/// 原子保存迁移阶段；旧配置和凭证没有完成确认前不写完成状态。
struct NivoProviderMigrationJournal {
    let fileURL: URL

    /// 不存在与损坏分别处理，受保护或不可读文件不会被重建。
    func read() throws -> NivoProviderMigrationPlan? {
        let data: Data
        do { data = try Data(contentsOf: fileURL) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
        let plan = try JSONDecoder().decode(NivoProviderMigrationPlan.self, from: data)
        try plan.validate()
        return plan
    }

    /// 首次操作前固定目标；重试复用原记录，不接受新随机身份覆盖它。
    func prepare(targets: [String: String]) throws -> NivoProviderMigrationPlan {
        if let existing = try read() { return existing }
        let plan = NivoProviderMigrationPlan(targets: targets)
        try save(plan)
        return plan
    }

    /// 每次推进核对磁盘基线，避免另一窗口或恢复操作改变计划后继续清理。
    func advance(_ plan: NivoProviderMigrationPlan, to phase: NivoProviderMigrationPlan.Phase) throws -> NivoProviderMigrationPlan {
        guard try read() == plan else { throw NivoPersonalBackupError.snapshotChanged }
        var next = plan
        next.phase = phase
        try save(next)
        return next
    }

    private func save(_ plan: NivoProviderMigrationPlan) throws {
        try plan.validate()
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(plan).write(to: fileURL, options: .atomic)
    }
}

/// 迁移的持久化顺序由生产核心统一管理，宿主注入Keychain和配置仓库。
@MainActor
enum NivoProviderMigrationTransaction {
    /// 配置落盘与新凭证复核后才清旧来源，任一失败保留原阶段供再次进入。
    static func run(journal: NivoProviderMigrationJournal, plan: NivoProviderMigrationPlan,
                    prepareCredentials: () throws -> Void,
                    persistConfiguration: () async throws -> Void,
                    verifyCredentials: () throws -> Void,
                    cleanupLegacy: () throws -> Void) async throws {
        guard try journal.read() == plan else { throw NivoPersonalBackupError.snapshotChanged }
        try Task.checkCancellation()
        if plan.phase == .completed { return }
        try prepareCredentials()
        try await persistConfiguration()
        try verifyCredentials()
        let confirmed = try journal.advance(plan, to: .configurationSaved)
        try cleanupLegacy()
        _ = try journal.advance(confirmed, to: .completed)
    }
}
