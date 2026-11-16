import Foundation

/// 普通凭证同步的解码与版本规则；秘密正文只在内存流转，不参与日志和错误文本。
enum NivoCredentialSync {
    enum Failure: Error { case invalidPayload }

    struct Entry: Sendable {
        let owner: String
        let value: Data
        let updatedAt: Date?
    }

    enum Decision: Equatable { case keep, write(Date) }

    /// 先验证完整输入，任何一条损坏都不能把本批记录确认成成功。
    static func providers(_ json: String) throws -> [Entry] {
        do {
            let payloads = try decode([ProviderPayload].self, json: json)
            return try validate(payloads.map {
                Entry(owner: $0.instanceId, value: try value($0.apiKey), updatedAt: $0.updatedAt)
            })
        } catch { throw Failure.invalidPayload }
    }

    /// 环境变量沿用仅补缺失值的协议，同时拒绝坏名称、重复项和坏正文。
    static func environments(_ json: String) throws -> [Entry] {
        do {
            let payloads = try decode([EnvironmentPayload].self, json: json)
            let entries = try validate(payloads.map {
                Entry(owner: $0.key, value: try value($0.value), updatedAt: nil)
            })
            for entry in entries {
                guard let first = entry.owner.first, first.isASCII, first.isLetter,
                      entry.owner.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }) else {
                    throw Failure.invalidPayload
                }
            }
            return entries
        } catch { throw Failure.invalidPayload }
    }

    private struct EnvironmentPayload: Decodable {
        let key: String
        let value: String
    }

    private struct ProviderPayload: Decodable {
        let instanceId: String
        let apiKey: String
        let updatedAt: Date?
        private enum CodingKeys: String, CodingKey { case instanceId, apiKey, updatedAt }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            instanceId = try values.decode(String.self, forKey: .instanceId)
            apiKey = try values.decode(String.self, forKey: .apiKey)
            guard values.contains(.updatedAt), try !values.decodeNil(forKey: .updatedAt) else {
                updatedAt = nil
                return
            }
            let seconds: Double
            if let number = try? values.decode(Double.self, forKey: .updatedAt) { seconds = number }
            else {
                let string = try values.decode(String.self, forKey: .updatedAt)
                guard let number = Double(string) else { throw Failure.invalidPayload }
                seconds = number
            }
            guard seconds.isFinite else { throw Failure.invalidPayload }
            updatedAt = Date(timeIntervalSince1970: seconds)
        }
    }

    private static func decode<T: Decodable>(_ type: T.Type, json: String) throws -> T {
        guard json.utf8.count <= 16_777_216 else { throw Failure.invalidPayload }
        return try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    private static func value(_ base64: String) throws -> Data {
        guard let value = Data(base64Encoded: base64), !value.isEmpty, value.count <= 1_048_576,
              String(data: value, encoding: .utf8) != nil else { throw Failure.invalidPayload }
        return value
    }

    private static func validate(_ entries: [Entry]) throws -> [Entry] {
        guard entries.count <= 4_096, Set(entries.map(\.owner)).count == entries.count,
              entries.allSatisfy({ !$0.owner.isEmpty && $0.owner.utf8.count <= 512 && !$0.owner.contains("\0") }) else {
            throw Failure.invalidPayload
        }
        return entries
    }

    /// 旧记录只补空值；带版本记录按已确认时间合并。
    static func decision(local: Data?, localUpdatedAt: Date, remote: Entry, now: Date) -> Decision {
        guard local != nil else { return .write(remote.updatedAt ?? now) }
        guard let version = remote.updatedAt, version > localUpdatedAt else { return .keep }
        return .write(version)
    }
}
