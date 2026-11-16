import Foundation

/// 分支只截取真实用户回合；工具结果和系统续写提示不占用回合数。
enum NivoChatBranchRules {
    /// 找到指定回合后的边界，缺少该回合时拒绝创建不完整的分支。
    static func prefix(_ rows: [RawMessage], userTurns: Int) throws -> [RawMessage] {
        guard userTurns > 0 else { throw NivoLifeError.invalidField("user_turns") }
        var seen = 0
        for (index, row) in rows.enumerated() where isUserTurn(row) {
            if seen == userTurns { return Array(rows.prefix(index)) }
            seen += 1
        }
        guard seen == userTurns else { throw NivoLifeError.operationConflict }
        return rows
    }

    /// 图片单独发送也属于用户回合，与安卓端保持一致。
    static func isUserTurn(_ row: RawMessage) -> Bool {
        guard row.role == .user else { return false }
        return row.parts.contains { part in
            switch part {
            case .text(let text):
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                return !trimmed.isEmpty && !trimmed.hasPrefix("<system-reminder>")
            case .mediaRef: return true
            case .toolUse, .toolResult: return false
            }
        }
    }

    /// 原图、工具结果图和工具快照一起复制，删除源会话后分支仍持有自己的文件。
    static func copyingMedia(_ parts: [ContentPart], copy: (MediaRef) throws -> MediaRef) throws -> [ContentPart] {
        try parts.map { part in
            switch part {
            case .mediaRef(let reference): return .mediaRef(try copy(reference))
            case .toolResult(let result):
                let image = try result.mediaRef.map(copy)
                let snapshot = try result.snapshot.map { snapshot in
                    ToolSnapshot(type: snapshot.type, text: snapshot.text,
                                 mediaRef: try snapshot.mediaRef.map(copy), duration: snapshot.duration)
                }
                return .toolResult(ToolResult(toolUseId: result.toolUseId, output: result.output,
                    success: result.success, mediaRef: image, snapshot: snapshot, pageURL: result.pageURL, status: result.status))
            case .text, .toolUse: return part
            }
        }
    }

    /// 只继承截取范围内的摘要，不能让后续对话通过压缩摘要进入较早的分支。
    static func remap(_ marker: CompactMarker, branchID: String,
                      messageIDs: [String: String], maximumSortOrder: Int) -> CompactMarker? {
        let references = [marker.firstKeptMessageId, marker.lastCompactedMessageId, marker.boundaryMessageId].compactMap { $0 }
        guard references.allSatisfy({ messageIDs[$0] != nil }) else { return nil }
        if marker.version == 2 {
            guard marker.lastCompactedMessageId != nil else { return nil }
        } else if references.isEmpty {
            // 旧格式只能按保留的排序边界判定，不能继承越过分支末尾的摘要。
            guard marker.firstKeptSortOrder > 0, marker.firstKeptSortOrder - 1 <= maximumSortOrder else { return nil }
        }
        return CompactMarker(id: UUID().uuidString, sessionId: branchID, summary: marker.summary,
            firstKeptSortOrder: marker.firstKeptSortOrder, compactedCount: marker.compactedCount,
            createdAt: marker.createdAt, uiBoundarySortOrder: marker.uiBoundarySortOrder,
            boundaryMessageId: marker.boundaryMessageId.flatMap { messageIDs[$0] },
            firstKeptMessageId: marker.firstKeptMessageId.flatMap { messageIDs[$0] },
            lastCompactedMessageId: marker.lastCompactedMessageId.flatMap { messageIDs[$0] }, version: marker.version)
    }
}
