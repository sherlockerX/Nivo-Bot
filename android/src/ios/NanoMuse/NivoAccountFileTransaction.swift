import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// 固定路径账户资料的可恢复事务；身份提交前始终保留完整旧副本。
struct NivoAccountFileTransaction: Sendable {
    struct Slot: Sendable {
        let name: String
        let live: URL
    }

    enum Phase: String, Codable, Sendable { case prepared, installed, committed, settled, rolledBack }

    struct Journal: Codable, Sendable {
        var version = 1
        let id: UUID
        let sourceOwner: String
        let targetOwner: String
        let keepSource: Bool
        let targetIdentity: Data
        let sourceNames: [String]
        let targetNames: [String]
        var phase: Phase = .prepared
        var isFinalizing: Bool { phase == .settled || phase == .rolledBack }
        var hasCommittedIdentity: Bool { phase == .committed || phase == .settled }
    }

    enum Checkpoint: Equatable, Sendable {
        case snapshot(String)
        case install(String)
        case archive
        case cleanup
    }

    typealias Fault = @Sendable (Checkpoint) throws -> Void
    let root: URL
    let slots: [Slot]
    private let fault: Fault
    // 在执行上下文取得管理器，跨actor只传递路径与事务值。
    private var manager: FileManager { .default }
    private var pending: URL { root.appendingPathComponent("pending-account-switch", isDirectory: true) }
    private var journalURL: URL { pending.appendingPathComponent("journal.json") }

    /// 所有写入路径来自宿主固定清单，日志不携带可执行的绝对路径。
    init(root: URL, slots: [Slot], fault: @escaping Fault = { _ in }) {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        self.slots = slots.map {
            Slot(name: $0.name, live: $0.live.standardizedFileURL.resolvingSymlinksInPath())
        }
        self.fault = fault
    }

    /// 先完整复制双方资料，成功落盘日志之前不修改活动路径或旧存档。
    func prepare(source: String, target: String, keepSource: Bool,
                 sourceDefaults: Data, targetIdentity: Data) throws -> Journal {
        guard source != target, try load() == nil else { throw NivoLifeError.operationConflict }
        try validateSlots()
        if manager.fileExists(atPath: pending.path) { try manager.removeItem(at: pending) }
        let sourceFolder = snapshot("source")
        let targetFolder = snapshot("target")
        try manager.createDirectory(at: sourceFolder, withIntermediateDirectories: true)
        try manager.createDirectory(at: targetFolder, withIntermediateDirectories: true)
        var sourceNames: [String] = []
        var targetNames: [String] = []
        for slot in slots {
            try fault(.snapshot(slot.name))
            if try copyIfPresent(slot.live, to: sourceFolder.appendingPathComponent(slot.name)) {
                sourceNames.append(slot.name)
            }
            let saved = archive(for: target).appendingPathComponent(slot.name)
            if try copyIfPresent(saved, to: targetFolder.appendingPathComponent(slot.name)) {
                targetNames.append(slot.name)
            }
        }
        try sourceDefaults.write(to: sourceFolder.appendingPathComponent("defaults.plist"), options: .atomic)
        let storedDefaults = archive(for: target).appendingPathComponent("defaults.plist")
        if !(try copyIfPresent(storedDefaults, to: targetFolder.appendingPathComponent("defaults.plist"))) {
            let empty = try PropertyListSerialization.data(fromPropertyList: [String: String](), format: .binary, options: 0)
            try empty.write(to: targetFolder.appendingPathComponent("defaults.plist"), options: .atomic)
        }
        // 损坏的偏好必须在修改活动路径前报错，不能悄悄按空字典恢复。
        try validateDefaults(in: sourceFolder)
        try validateDefaults(in: targetFolder)
        let journal = Journal(id: UUID(), sourceOwner: source, targetOwner: target, keepSource: keepSource,
            targetIdentity: targetIdentity, sourceNames: sourceNames, targetNames: targetNames)
        try save(journal)
        return journal
    }

    /// 身份未变更时仅安装候选文件；失败可从source完整恢复。
    func installTarget() throws {
        var journal = try requireJournal()
        guard !journal.hasCommittedIdentity, !journal.isFinalizing else { return }
        try install(snapshot("target"), names: journal.targetNames, journal: journal)
        journal.phase = .installed
        try save(journal)
    }

    /// 身份凭证已经提交后才调用，随后可幂等完成旧账户存档或删除。
    func markCommitted() throws {
        var journal = try requireJournal()
        guard journal.phase == .installed || journal.phase == .committed else { throw NivoLifeError.operationConflict }
        journal.phase = .committed
        try save(journal)
    }

    /// 断电恢复由宿主核验密钥身份；文件层不凭调用时的旧缓存猜测账户。
    func recoverFiles(useTarget: Bool) throws -> Journal {
        var journal = try requireJournal()
        if journal.isFinalizing {
            guard useTarget == journal.hasCommittedIdentity else { throw NivoLifeError.operationConflict }
            return journal
        }
        let side = useTarget ? "target" : "source"
        let names = useTarget ? journal.targetNames : journal.sourceNames
        try install(snapshot(side), names: names, journal: journal)
        if useTarget {
            journal.phase = .committed
            try save(journal)
        }
        return journal
    }

    /// 返回相同快照中的偏好，宿主只恢复账户键，设备设置不参与切换。
    func defaults(useTarget: Bool) throws -> Data {
        _ = try requireJournal()
        let directory = snapshot(useTarget ? "target" : "source")
        try validateDefaults(in: directory)
        return try Data(contentsOf: directory.appendingPathComponent("defaults.plist"))
    }

    /// 提交后归档源账户；只在其他账户仓库和聊天清理完成后删除事务日志。
    func settleArchive() throws {
        let journal = try requireJournal()
        guard journal.phase == .committed else { throw NivoLifeError.operationConflict }
        try fault(.archive)
        let destination = archive(for: journal.sourceOwner)
        if journal.keepSource {
            try replace(destination, from: snapshot("source"), journal: journal, name: "archive")
        } else if manager.fileExists(atPath: destination.path) {
            try manager.removeItem(at: destination)
        }
    }

    /// 最后一步单独执行；清理失败保留日志，下一次启动继续相同事务。
    func finish() throws {
        var journal = try requireJournal()
        if !journal.isFinalizing {
            journal.phase = journal.hasCommittedIdentity ? .settled : .rolledBack
            try save(journal)
        }
        try fault(.cleanup)
        // settled/rolledBack表示活动文件与偏好已经落盘，清理中断时不能再覆盖活动目录。
        // 先删除含有原账户资料的快照，失败保留明确的清理日志，不能把“删除资料”报告为成功。
        for side in ["source", "target"] where manager.fileExists(atPath: snapshot(side).path) {
            try manager.removeItem(at: snapshot(side))
        }
        try manager.removeItem(at: journalURL)
        // 此时只剩空目录，不再包含用户资料。
        try? manager.removeItem(at: pending)
    }

    /// 日志损坏时保留资料并拒绝继续切换，避免覆盖唯一恢复副本。
    func load() throws -> Journal? {
        guard manager.fileExists(atPath: journalURL.path) else { return nil }
        let data = try Data(contentsOf: journalURL)
        guard data.count <= 1_048_576 else { throw NivoLifeError.corruptStore }
        let journal = try JSONDecoder().decode(Journal.self, from: data)
        let allowed = Set(slots.map(\.name))
        guard journal.version == 1, journal.sourceOwner != journal.targetOwner,
              Set(journal.sourceNames).isSubset(of: allowed), Set(journal.targetNames).isSubset(of: allowed),
              Set(journal.sourceNames).count == journal.sourceNames.count,
              Set(journal.targetNames).count == journal.targetNames.count else { throw NivoLifeError.corruptStore }
        return journal
    }

    /// 继续使用旧版账户目录名，升级不搬动尚未登录的存档。
    func archive(for owner: String) -> URL {
        let name = owner.isEmpty ? "_local" : String(SHA256.hash(data: Data(owner.utf8))
            .map { String(format: "%02x", $0) }.joined().prefix(16))
        return root.appendingPathComponent("accounts", isDirectory: true).appendingPathComponent(name, isDirectory: true)
    }

    private func requireJournal() throws -> Journal {
        guard let journal = try load() else { throw NivoLifeError.operationConflict }
        return journal
    }

    private func save(_ journal: Journal) throws {
        try JSONEncoder().encode(journal).write(to: journalURL, options: .atomic)
    }

    private func snapshot(_ name: String) -> URL { pending.appendingPathComponent(name, isDirectory: true) }

    private func validateSlots() throws {
        let names = slots.map(\.name)
        guard Set(names).count == names.count, names.allSatisfy({
            !$0.isEmpty && $0 != "." && $0 != ".." && $0 != "defaults.plist"
                && !$0.contains("/") && !$0.contains("\\")
        }) else { throw NivoLifeError.invalidField("account_path") }
    }

    private func validateDefaults(in directory: URL) throws {
        let data = try Data(contentsOf: directory.appendingPathComponent("defaults.plist"))
        guard try PropertyListSerialization.propertyList(from: data, options: [], format: nil) is [String: Any] else {
            throw NivoLifeError.corruptStore
        }
    }

    private func copyIfPresent(_ source: URL, to destination: URL) throws -> Bool {
        guard manager.fileExists(atPath: source.path) else { return false }
        try manager.copyItem(at: source, to: destination)
        return true
    }

    private func install(_ directory: URL, names: [String], journal: Journal) throws {
        // 完整检查快照后才写第一条，不能把被删坏的快照当作本来就没有资料。
        for name in names where !manager.fileExists(atPath: directory.appendingPathComponent(name).path) {
            throw NivoLifeError.corruptStore
        }
        for slot in slots {
            try fault(.install(slot.name))
            let source = names.contains(slot.name) ? directory.appendingPathComponent(slot.name) : nil
            try replace(slot.live, from: source, journal: journal, name: slot.name)
        }
    }

    private func replace(_ destination: URL, from source: URL?, journal: Journal, name: String) throws {
        let parent = destination.deletingLastPathComponent()
        try manager.createDirectory(at: parent, withIntermediateDirectories: true)
        let prefix = ".nivo-account-" + journal.id.uuidString + "-" + name
        let staged = parent.appendingPathComponent(prefix + "-new")
        let previous = parent.appendingPathComponent(prefix + "-old")
        if manager.fileExists(atPath: staged.path) { try manager.removeItem(at: staged) }
        // 先在目标卷复制；跨AppGroup卷时不会在复制失败后删掉活动资料。
        if let source { try manager.copyItem(at: source, to: staged) }
        if manager.fileExists(atPath: previous.path) { try manager.removeItem(at: previous) }
        if manager.fileExists(atPath: destination.path) { try manager.moveItem(at: destination, to: previous) }
        do {
            if source != nil { try manager.moveItem(at: staged, to: destination) }
        } catch {
            if manager.fileExists(atPath: previous.path) { try manager.moveItem(at: previous, to: destination) }
            throw error
        }
        if manager.fileExists(atPath: previous.path) { try manager.removeItem(at: previous) }
    }
}
