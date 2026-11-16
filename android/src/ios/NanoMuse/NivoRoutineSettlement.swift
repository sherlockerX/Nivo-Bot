import Foundation

/// 业务已经结束的收据，主档案写入失败时只重试结算，不重新请求模型或执行工具。
struct NivoRoutineSettlement: Codable, Equatable, Sendable {
    var routineID: String
    var routineCreatedAt: Date
    var run: NanoMuseRoutine.Run

    /// 只替换同一任务同一次运行的未结算记录，重复回放不会重复计数。
    func applying(to rows: [NanoMuseRoutine]) throws -> [NanoMuseRoutine] {
        guard let taskIndex = rows.firstIndex(where: { $0.id == routineID && $0.createdAt == routineCreatedAt }),
              let runIndex = rows[taskIndex].runs.firstIndex(where: { $0.id == run.id }),
              ["running", "interrupted"].contains(rows[taskIndex].runs[runIndex].status ?? "") else { return rows }
        var result = rows
        var row = result[taskIndex]
        guard (row.revision ?? 0) < Int64.max else { throw NivoLifeError.invalidField("revision") }
        row.runs[runIndex] = run
        row.lastSessionID = run.sessionId
        if row.execution == nil, row.sessionId == nil { row.sessionId = run.sessionId }
        if run.isDebug != true {
            row.consecutiveFailures = run.ok ? 0 : min(1_000_000, (row.consecutiveFailures ?? 0) + 1)
            if !run.ok { row.totalFailures = min(1_000_000_000, (row.totalFailures ?? 0) + 1) }
        }
        if row.repeatMode == .once, row.intervalHours == nil, row.schedule?.intervalMinutes == nil { row.enabled = false }
        if run.isDebug != true, let execution = row.execution, execution.autoDisableOnFailure,
           (row.consecutiveFailures ?? 0) >= execution.failureThreshold { row.enabled = false }
        row.revision = (row.revision ?? 0) + 1
        result[taskIndex] = row
        return result
    }
}

/// 有界收据目录在账户切换时一起移动，文件名只使用宿主生成的运行UUID。
enum NivoRoutineSettlementFiles {
    static let maximumBytes = 1_024 * 1_024

    /// 先落盘收据后更新主档案；收据保留业务结果和真实时间，不含执行令牌。
    static func stage(_ receipt: NivoRoutineSettlement, directory: URL) throws {
        let file = try file(receipt, directory: directory)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(receipt)
        guard data.count <= maximumBytes else { throw NivoLifeError.invalidField("routine_settlement_size") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
    }

    /// 主档案没有对应任务时丢弃收据，不恢复用户已经删除的任务。
    static func read(directory: URL) throws -> [NivoRoutineSettlement] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let files = try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]).filter { $0.pathExtension == "json" }
        guard files.count <= 1_000 else { throw NivoLifeError.invalidField("routine_settlements") }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try files.sorted { $0.lastPathComponent < $1.lastPathComponent }.map { url in
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize,
                  size <= maximumBytes else { throw NivoLifeError.invalidField("routine_settlement") }
            let receipt = try decoder.decode(NivoRoutineSettlement.self, from: Data(contentsOf: url))
            guard try file(receipt, directory: directory) == url else { throw NivoLifeError.invalidField("routine_settlement") }
            return receipt
        }
    }

    /// 只有主档案已写入后才删除收据，删除失败可在下一次启动重复结算。
    static func clear(_ receipt: NivoRoutineSettlement, directory: URL) throws {
        let url = try file(receipt, directory: directory)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    private static func file(_ receipt: NivoRoutineSettlement, directory: URL) throws -> URL {
        guard let id = receipt.run.id, UUID(uuidString: id) != nil,
              ["completed", "failed"].contains(receipt.run.status ?? ""), receipt.run.finishedAt != nil,
              (receipt.run.status == "completed") == receipt.run.ok,
              let duration = receipt.run.duration, duration.isFinite, duration >= 0,
              (receipt.run.result?.utf8.count ?? 0) <= NivoRoutineRunRules.maximumResultBytes else {
            throw NivoLifeError.invalidField("routine_settlement")
        }
        return directory.appendingPathComponent(id + ".json")
    }
}
