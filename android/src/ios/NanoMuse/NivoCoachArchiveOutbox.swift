import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// 首次暂存固定账户、课次和原文签名，重启重试不得把旧回复绑定到新课次。
struct NivoCoachArchiveEntry: Codable, Equatable, Sendable {
    var ownerKey: String
    var chatID: String
    var lessonID: String
    var messageID: String
    var role: String
    var text: String
    var digest: String
}

/// 单项损坏不会隐藏其他待整理消息，错误与健康记录同时返回。
struct NivoCoachArchiveRead: Sendable {
    var entries: [NivoCoachArchiveEntry] = []
    var failures: [String] = []
}

/// 由教练actor串行调用的文件队列，每条消息独立原子写入。
struct NivoCoachArchiveFiles {
    let directory: URL
    let writer: NivoCoachV2Store.Writer

    /// 同一原话重试保留首次课次，改写的来源必须先被撤销。
    @discardableResult
    func put(_ entry: NivoCoachArchiveEntry) throws -> NivoCoachArchiveEntry {
        try validate(entry)
        let path = file(entry)
        if FileManager.default.fileExists(atPath: path.path) {
            let previous = try decode(path, owner: entry.ownerKey, chatID: entry.chatID)
            guard previous.ownerKey == entry.ownerKey, previous.chatID == entry.chatID,
                  previous.role == entry.role, previous.text == entry.text,
                  previous.digest == entry.digest else { throw NivoLifeError.operationConflict }
            return previous
        }
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writer(JSONEncoder().encode(entry), path)
        return entry
    }

    /// 损坏条目保留磁盘原件，不把解码失败当作空队列。
    func read(owner: String, chatID: String) -> NivoCoachArchiveRead {
        var result = NivoCoachArchiveRead()
        let folder = folder(owner: owner, chatID: chatID)
        guard FileManager.default.fileExists(atPath: folder.path) else { return result }
        do {
            let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            for path in files where path.pathExtension == "json" {
                do { result.entries.append(try decode(path, owner: owner, chatID: chatID)) }
                catch { result.failures.append(error.localizedDescription) }
            }
        } catch { result.failures.append(error.localizedDescription) }
        return result
    }

    /// 只删除已确认处理的单条来源，不递归清空聊天或其他账户。
    func remove(_ entry: NivoCoachArchiveEntry) throws {
        try validate(entry)
        let path = file(entry)
        if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
    }

    private func decode(_ path: URL, owner: String, chatID: String) throws -> NivoCoachArchiveEntry {
        let data = try Data(contentsOf: path)
        guard data.count <= 2_000_000 else { throw NivoLifeError.corruptStore }
        let value = try JSONDecoder().decode(NivoCoachArchiveEntry.self, from: data)
        try validate(value)
        guard value.ownerKey == owner, value.chatID == chatID, file(value) == path else { throw NivoLifeError.corruptStore }
        return value
    }

    private func validate(_ entry: NivoCoachArchiveEntry) throws {
        // 未登录的本机账户使用空字符串，这是合法账户键，仍按SHA256隔离目录。
        guard !entry.chatID.isEmpty, !entry.lessonID.isEmpty,
              !entry.messageID.isEmpty, ["user", "assistant"].contains(entry.role),
              !entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              entry.text.utf8.count <= 1_500_000, entry.digest.count == 64 else { throw NivoLifeError.invalidField("coach_archive_source") }
    }

    private func file(_ entry: NivoCoachArchiveEntry) -> URL {
        folder(owner: entry.ownerKey, chatID: entry.chatID).appendingPathComponent(hash(entry.messageID) + ".json")
    }

    private func folder(owner: String, chatID: String) -> URL {
        directory.appendingPathComponent(hash(owner)).appendingPathComponent("archive-outbox").appendingPathComponent(hash(chatID))
    }

    private func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// 从暂存开始到SQLite确认之间显式保留消息，恢复任务不能误删仍在写入的意图。
@MainActor
enum NivoCoachArchiveWrites {
    private static var pending = Set<String>()
    static var isBusy: Bool { !pending.isEmpty }

    static func begin(_ messageID: String) { pending.insert(messageID) }
    static func end(_ messageID: String) { pending.remove(messageID) }
    static func contains(_ messageID: String) -> Bool { pending.contains(messageID) }
}
