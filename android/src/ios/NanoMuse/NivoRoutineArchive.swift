import Foundation

/// 定时任务文件采用先验证再原子替换，损坏文件不降级为空列表后覆盖。
enum NivoRoutineArchive {
    static let maximumBytes = 16 * 1_024 * 1_024

    /// 设置损坏时报告读取错误，不自动以默认值覆盖用户保存的静音时段。
    static func readSettings(_ file: URL) throws -> NivoRoutineNotificationSettings {
        guard FileManager.default.fileExists(atPath: file.path) else { return NivoRoutineNotificationSettings() }
        let values = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let bytes = values.fileSize, bytes <= 4_096 else { throw NivoLifeError.invalidField("routine_settings") }
        let settings = try JSONDecoder().decode(NivoRoutineNotificationSettings.self, from: Data(contentsOf: file))
        try NivoRoutineNotificationRules.validateQuietHours(settings.quietHours)
        return settings
    }

    /// 先验证再原子写入，失败时旧设置仍可读取。
    static func writeSettings(_ settings: NivoRoutineNotificationSettings, to file: URL) throws {
        try NivoRoutineNotificationRules.validateQuietHours(settings.quietHours)
        let data = try JSONEncoder().encode(settings)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
    }

    /// 老任务保留原字段，新增配置缺席时仍可以读取。
    static func read(_ file: URL) throws -> [NanoMuseRoutine] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        let values = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let bytes = values.fileSize, bytes <= maximumBytes else { throw NivoLifeError.invalidField("routines_file") }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let rows = try decoder.decode([NanoMuseRoutine].self, from: Data(contentsOf: file))
        try validate(rows)
        return rows
    }

    /// 成功返回后调用方才发布内存状态；失败仍保留旧文件。
    static func write(_ rows: [NanoMuseRoutine], to file: URL) throws {
        try validate(rows)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(rows)
        guard data.count <= maximumBytes else { throw NivoLifeError.invalidField("routines_file_size") }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
    }

    /// 备份与本机写入共用整档验证，避免重复标识在合并时崩溃。
    static func validate(_ rows: [NanoMuseRoutine]) throws {
        guard rows.count <= 1_000, Set(rows.map(\.id)).count == rows.count else {
            throw NivoLifeError.invalidField("routine_ids")
        }
        let sessions = rows.compactMap(\.dedicatedSessionID)
        guard Set(sessions).count == sessions.count else { throw NivoLifeError.invalidField("dedicated_session_ids") }
        for row in rows { try NivoRoutineScheduleRules.validate(row) }
    }
}
