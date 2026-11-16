import Foundation

/// 环境变量的非秘密元数据；值继续仅保存在Keychain。
struct EnvVarEntry: Identifiable, Codable, Equatable, Sendable {
    let id: String
    var key: String
    var createdAt: Date
    var note: String
    var updatedAt: Date?

    init(id: String = UUID().uuidString, key: String, createdAt: Date = Date(), note: String = "", updatedAt: Date? = nil) {
        self.id = id
        self.key = key
        self.createdAt = createdAt
        self.note = note
        self.updatedAt = updatedAt
    }

    /// 兼容没有备注及修改时间的旧元数据。
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        key = try values.decode(String.self, forKey: .key)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        note = try values.decodeIfPresent(String.self, forKey: .note) ?? ""
        updatedAt = try values.decodeIfPresent(Date.self, forKey: .updatedAt)
    }

    var version: Date { updatedAt ?? createdAt }
}

/// 单变量同步与真实元数据文件共用的校验、版本规则。
enum NivoEnvVarState {
    enum Failure: Error { case invalidRecord, duplicateKey }

    /// 旧发送端的缺省值表示未提供秘密，损坏正文不能按该含义处理。
    static func decodeValue(_ encoded: String?) throws -> String? {
        guard let encoded, !encoded.isEmpty else { return nil }
        guard encoded.utf8.count <= 1_398_104, let data = Data(base64Encoded: encoded),
              data.count <= 1_048_576, let value = String(data: data, encoding: .utf8) else {
            throw Failure.invalidRecord
        }
        return value
    }

    /// 新版本输入与本机已确认版本比较；相同版本重放不重复覆盖。
    static func accepts(remote: Date, local: EnvVarEntry?) -> Bool {
        guard let local else { return true }
        return remote > local.version
    }

    /// 本机修改必须晚于已见版本，设备时间回拨不能退回旧版本。
    static func nextVersion(after previous: Date, now: Date) throws -> Date {
        let old = previous.timeIntervalSince1970
        let current = now.timeIntervalSince1970
        guard old.isFinite, current.isFinite else { throw Failure.invalidRecord }
        let seconds = max(current, max(old + 0.001, old.nextUp))
        guard seconds.isFinite else { throw Failure.invalidRecord }
        return Date(timeIntervalSince1970: seconds)
    }

    /// 校验元数据，调用者在触碰Keychain前执行。
    static func validate(_ entries: [EnvVarEntry]) throws {
        guard entries.count <= 4_096, Set(entries.map(\.id)).count == entries.count else { throw Failure.invalidRecord }
        guard Set(entries.map(\.key)).count == entries.count else { throw Failure.duplicateKey }
        for entry in entries {
            guard !entry.id.isEmpty, entry.id.utf8.count <= 512, !entry.id.contains("\0"),
                  entry.key.utf8.count <= 512, let first = entry.key.first, first.isASCII, first.isLetter,
                  entry.key.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }),
                  entry.note.utf8.count <= 65_536, entry.createdAt.timeIntervalSince1970.isFinite,
                  entry.version.timeIntervalSince1970.isFinite else { throw Failure.invalidRecord }
        }
    }

    /// 保留最早创建时间；相同名称的不同身份不能悄悄覆盖同一Keychain条目。
    static func merging(_ incoming: EnvVarEntry, into entries: [EnvVarEntry]) throws -> [EnvVarEntry]? {
        try validate(entries)
        try validate([incoming])
        let old = entries.first { $0.id == incoming.id }
        guard accepts(remote: incoming.version, local: old) else { return nil }
        guard !entries.contains(where: { $0.key == incoming.key && $0.id != incoming.id }) else { throw Failure.duplicateKey }
        var replacement = incoming
        if let old { replacement.createdAt = min(old.createdAt, incoming.createdAt) }
        return entries.filter { $0.id != incoming.id } + [replacement]
    }

    /// 原子读取，文件缺少可以从空列表开始，损坏或权限错误必须保留原件。
    static func read(_ url: URL) throws -> [EnvVarEntry] {
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return [] }
        guard data.count <= 16_777_216 else { throw Failure.invalidRecord }
        let entries = try JSONDecoder().decode([EnvVarEntry].self, from: data)
        try validate(entries)
        return entries
    }

    /// 文件提交成功后，宿主才发布候选元数据并确认远端记录。
    static func save(_ entries: [EnvVarEntry], to url: URL) throws {
        try validate(entries)
        let data = try JSONEncoder().encode(entries)
        guard data.count <= 16_777_216 else { throw Failure.invalidRecord }
        try data.write(to: url, options: .atomic)
    }
}
