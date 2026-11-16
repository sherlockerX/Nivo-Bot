import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// 导入签名只含文件摘要，相同内容重试不会再次写入任务。
private struct NivoTodoImportRequest: Codable {
    var action = "import_todo_backup"
    var digest: String
}

/// 专注导出沿用安卓格式，计量区间和会话来自同一份快照。
private struct NivoFocusBackupDocument: Encodable {
    var format = "nanomuse-focus"
    var version = 1
    var sessions: [NivoFocusBackupSession]
    var spans: [NivoFocusSpan]
}

/// 导出字段匹配安卓FocusJson，设备重启标识不可跨平台复用，因此使用无效代次。
private struct NivoFocusBackupSession: Encodable {
    var value: NivoFocusSession

    func encode(to encoder: Encoder) throws {
        try value.encode(to: encoder)
        var keys = encoder.container(keyedBy: ExtraKeys.self)
        try keys.encode(-1, forKey: .bootCount)
    }

    private enum ExtraKeys: String, CodingKey { case bootCount }
}

extension NivoLifeRepository {
    /// 获取完整任务JSON，不从经过筛选的界面数组导出。
    func exportTasks(scope: NivoLifeScope, clock: NivoFocusClockSample) throws -> Data {
        try NivoTodoBackupCodec.encode(snapshot(scope: scope, clock: clock))
    }

    /// 所有任务、分类和关联在一次提交中恢复，校验失败不留下部分结果。
    func importTasks(_ data: Data, scope: NivoLifeScope, now: Int64, today: Int64) throws -> NivoTodoImportResult {
        let document = try NivoTodoBackupCodec.decode(data, owner: scope.ownerKey, now: now, today: today)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return try transactionResult(operationID: "import:" + digest, request: NivoTodoImportRequest(digest: digest),
            scope: scope, recordsTaskChanges: false) { state in
                try NivoTodoBackupCodec.merge(document, into: &state, now: now)
            }.value
    }

    /// 导出副本结算到当前时刻，本机正在运行的计时继续，不把目标时长当作实测时长。
    func exportFocus(scope: NivoLifeScope, clock: NivoFocusClockSample) throws -> Data {
        var value = try snapshot(scope: scope, clock: clock)
        if let index = value.focusSessions.firstIndex(where: { $0.isActive && $0.status == .running }) {
            try settleFocus(at: index, state: &value, clock: clock)
        }
        let sessions = value.focusSessions.filter { $0.deletedAt == nil }
        let identifiers = Set(sessions.map(\.id))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(NivoFocusBackupDocument(sessions: sessions.map { NivoFocusBackupSession(value: $0) },
            spans: value.focusSpans.filter { identifiers.contains($0.sessionId) }))
        guard data.count <= NivoTodoBackupCodec.maximumBytes else { throw NivoLifeError.invalidField("backup_size") }
        return data
    }
}
