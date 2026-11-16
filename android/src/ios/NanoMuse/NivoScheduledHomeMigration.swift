import Foundation

/// 挂载前先保留旧home；完整原件和迁移收据留在账户目录，失败后可以继续。
struct NivoScheduledHomeMigration: Sendable {
    struct Receipt: Codable, Equatable, Sendable {
        var version = 1
        var copied: [String] = []
        var conflicts: [String] = []
        var skipped: [String] = []
    }

    enum Checkpoint: Equatable, Sendable { case archived, copying(String), staged(String), recording }
    typealias Fault = @Sendable (Checkpoint) throws -> Void

    let home: URL
    let legacyHome: URL
    private let fault: Fault
    private let manager = FileManager.default
    private var archives: URL { home.appendingPathComponent(".legacy-home-migrations", isDirectory: true) }

    /// 路径由宿主提供；只规范化父目录，不提前跟随待检查节点的符号链接。
    init(home: URL, legacyHome: URL, fault: @escaping Fault = { _ in }) {
        self.home = Self.normalizedNode(home)
        self.legacyHome = Self.normalizedNode(legacyHome)
        self.fault = fault
    }

    /// 只有本方法成功返回后才允许底层挂载替换旧路径，原件不会被删除。
    @discardableResult
    func prepare() throws -> [Receipt] {
        guard home.path != legacyHome.path,
              !home.path.hasPrefix(legacyHome.path + "/"),
              !legacyHome.path.hasPrefix(home.path + "/") else {
            throw NivoLifeError.invalidField("SCRIPT_HOME_PATH_CONFLICT")
        }
        try requireDirectory(home)
        try requireDirectory(home.appendingPathComponent("bin"))
        try requireDirectory(archives)
        var receipts = try resumePending()
        guard let kind = try nodeType(legacyHome) else { return receipts }
        if kind == .typeSymbolicLink {
            guard legacyHome.resolvingSymlinksInPath().standardizedFileURL.path == home.standardizedFileURL.path else {
                throw NivoLifeError.invalidField("SCRIPT_HOME_LINK_CONFLICT")
            }
            return receipts
        }
        guard kind == .typeDirectory else { throw NivoLifeError.invalidField("SCRIPT_HOME_UNAVAILABLE") }
        let batch = archives.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: batch, withIntermediateDirectories: false)
        // 原子改名先于任何合并；复制失败、挂载失败或应用终止都保留完整旧目录。
        try manager.moveItem(at: legacyHome, to: batch.appendingPathComponent("original", isDirectory: true))
        try fault(.archived)
        receipts.append(try merge(batch))
        return receipts
    }

    private func resumePending() throws -> [Receipt] {
        var receipts: [Receipt] = []
        for batch in try manager.contentsOfDirectory(at: archives, includingPropertiesForKeys: nil) {
            guard UUID(uuidString: batch.lastPathComponent) != nil,
                  try nodeType(batch) == .typeDirectory else { throw NivoLifeError.corruptStore }
            let original = batch.appendingPathComponent("original")
            let record = batch.appendingPathComponent("receipt.json")
            if try nodeType(record) != nil {
                guard try nodeType(record) == .typeRegular else { throw NivoLifeError.corruptStore }
                let receipt = try JSONDecoder().decode(Receipt.self, from: Data(contentsOf: record))
                guard receipt.version == 1, try nodeType(original) == .typeDirectory else { throw NivoLifeError.corruptStore }
            } else if try nodeType(original) != nil {
                receipts.append(try merge(batch))
            }
        }
        return receipts
    }

    private func merge(_ batch: URL) throws -> Receipt {
        let original = batch.appendingPathComponent("original", isDirectory: true)
        guard try nodeType(original) == .typeDirectory else { throw NivoLifeError.corruptStore }
        var receipt = Receipt()
        var directories = [(source: original, destination: home, relative: "")]
        while let directory = directories.popLast() {
            for source in try manager.contentsOfDirectory(at: directory.source, includingPropertiesForKeys: nil) {
                let relative = directory.relative + source.lastPathComponent
                let destination = directory.destination.appendingPathComponent(source.lastPathComponent)
                if source.lastPathComponent == archives.lastPathComponent && directory.relative.isEmpty {
                    receipt.skipped.append(relative)
                    continue
                }
                if try mergeNode(source, to: destination, staging: batch, relative: relative, receipt: &receipt) {
                    directories.append((source, destination, relative + "/"))
                }
            }
        }
        try fault(.recording)
        try JSONEncoder().encode(receipt).write(to: batch.appendingPathComponent("receipt.json"), options: .atomic)
        return receipt
    }

    private func mergeNode(_ source: URL, to destination: URL, staging: URL, relative: String, receipt: inout Receipt) throws -> Bool {
        let sourceType = try nodeType(source)
        guard sourceType == .typeDirectory || sourceType == .typeRegular else {
            receipt.skipped.append(relative)
            return false
        }
        let destinationType = try nodeType(destination)
        if sourceType == .typeDirectory && (destinationType == nil || destinationType == .typeDirectory) {
            try requireDirectory(destination)
            return true
        }
        if destinationType != nil {
            if destinationType != .typeRegular || sourceType != .typeRegular
                || !manager.contentsEqual(atPath: source.path, andPath: destination.path) {
                receipt.conflicts.append(relative)
            }
            return false
        }
        try fault(.copying(relative))
        // 先复制到归档内临时文件，磁盘耗尽或中断不能留下占用正式文件名的半份脚本。
        let temporary = staging.appendingPathComponent(".copy-" + UUID().uuidString)
        defer { try? manager.removeItem(at: temporary) }
        try manager.copyItem(at: source, to: temporary)
        try fault(.staged(relative))
        try manager.moveItem(at: temporary, to: destination)
        receipt.copied.append(relative)
        return false
    }

    private func requireDirectory(_ directory: URL) throws {
        if try nodeType(directory) == nil {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        guard try nodeType(directory) == .typeDirectory else { throw NivoLifeError.invalidField("SCRIPT_HOME_UNAVAILABLE") }
    }

    private func nodeType(_ url: URL) throws -> FileAttributeType? {
        do { return try manager.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile { return nil }
    }

    private static func normalizedNode(_ url: URL) -> URL {
        url.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(url.lastPathComponent)
    }
}
