import Foundation

/// 模型组成员历史的兼容读取；缺少旧字段可以为空，损坏的现有字段不能降级为空集合。
enum NivoProviderMemberHistory {
    /// 新协议同时携带加入和删除时间，旧协议仅携带扁平的删除时间表。
    struct History: Equatable, Sendable {
        let added: [String: Date]
        let removed: [String: Date]
    }

    /// 接收旧扁平协议与当前信封协议，拒绝损坏时间戳，保留上层同步重放机会。
    static func decode(_ encoded: String?) throws -> History {
        guard let encoded, !encoded.isEmpty else { return .init(added: [:], removed: [:]) }
        let data = Data(encoded.utf8)
        if let legacy = try? JSONDecoder().decode([String: Double].self, from: data) {
            return .init(added: [:], removed: try dates(legacy))
        }
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        return .init(added: try dates(envelope.added), removed: try dates(envelope.removed))
    }

    /// 本机数据库中的单侧历史采用严格读取，兼容迁移前缺少字段的情况。
    static func decodeMap(_ encoded: String?) throws -> [String: Date] {
        guard let encoded, !encoded.isEmpty else { return [:] }
        return try dates(JSONDecoder().decode([String: Double].self, from: Data(encoded.utf8)))
    }

    private static func dates(_ values: [String: Double]) throws -> [String: Date] {
        guard values.values.allSatisfy(\.isFinite) else { throw NivoPersonalBackupError.invalidPackage }
        return values.mapValues { Date(timeIntervalSince1970: $0) }
    }

    private struct Envelope: Decodable {
        let added: [String: Double]
        let removed: [String: Double]

        private enum CodingKeys: String, CodingKey { case added, removed }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            guard values.contains(.added) || values.contains(.removed) else {
                throw NivoPersonalBackupError.invalidPackage
            }
            added = values.contains(.added) ? try values.decode([String: Double].self, forKey: .added) : [:]
            removed = values.contains(.removed) ? try values.decode([String: Double].self, forKey: .removed) : [:]
        }
    }
}
