import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// 任务home的真实文件读写规则；备份格式转换留给宿主，路径和内容校验可独立验证。
struct NivoRoutineHomeFiles {
    struct Node {
        var path: String
        var url: URL
        var kind: FileAttributeType
    }

    struct Entry: Equatable, Sendable {
        var path: String
        var size: Int64 = 0
        var digest: String?
        var isDirectory = false
        var isSkipped = false
    }

    struct Restored: Equatable, Sendable {
        var files = 0
        var bytes: Int64 = 0
        var conflicts: [String] = []
        var skipped = 0
    }

    let home: URL
    private let manager = FileManager.default

    /// 只枚举真实目录；链接与特殊节点保留索引，不递归跟随到home以外。
    func scan() throws -> [Node] {
        guard try nodeType(home) == .typeDirectory else { throw NivoPersonalBackupError.invalidPackage }
        var pending = [(home, "")]
        var nodes: [Node] = []
        while let (directory, relative) = pending.popLast() {
            for source in try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                let path = relative + source.lastPathComponent
                try NivoRoutineBackup.validatePath(path)
                guard let kind = try nodeType(source) else { throw NivoPersonalBackupError.snapshotChanged }
                nodes.append(Node(path: path, url: source, kind: kind))
                guard nodes.count <= 20_000 else { throw NivoPersonalBackupError.invalidPackage }
                if kind == .typeDirectory { pending.append((source, path + "/")) }
            }
        }
        return nodes.sorted { $0.path < $1.path }
    }

    /// 同名内容保持本机版本；新文件校验后先暂存再改名，写入失败由外层回滚整类数据。
    func restore(_ entries: [Entry], expected: [String], packageRoot: URL,
                 afterStaging: (String) throws -> Void = { _ in }) throws -> Restored {
        try validate(entries, expected: expected)
        try requireDirectory(home)
        var result = Restored()
        for entry in entries.sorted(by: { $0.path < $1.path }) {
            if entry.isSkipped { result.skipped += 1; continue }
            guard let target = try destination(entry.path, isDirectory: entry.isDirectory) else {
                result.conflicts.append(entry.path)
                continue
            }
            if entry.isDirectory { continue }
            let source = try verifiedBlob(entry, root: packageRoot)
            if let kind = try nodeType(target) {
                if try kind != .typeRegular || Self.digest(target) != entry.digest {
                    result.conflicts.append(entry.path)
                }
                continue
            }
            try install(source, entry: entry, target: target, afterStaging: afterStaging)
            result.files += 1
            result.bytes += entry.size
        }
        return result
    }

    /// 按块计算实际内容摘要，超大脚本资料不会一次载入内存。
    static func digest(_ file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            // Apple平台逐块释放Foundation临时对象，避免长文件导致内存随总大小增长。
            #if canImport(ObjectiveC)
            let done = try autoreleasepool { () -> Bool in
                let chunk = try handle.read(upToCount: 1_024 * 1_024) ?? Data()
                hasher.update(data: chunk)
                return chunk.isEmpty
            }
            #else
            let chunk = try handle.read(upToCount: 1_024 * 1_024) ?? Data()
            hasher.update(data: chunk)
            let done = chunk.isEmpty
            #endif
            if done { break }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func validate(_ entries: [Entry], expected: [String]) throws {
        guard expected.count <= 20_000, entries.count == expected.count,
              Set(expected).count == expected.count, Set(entries.map(\.path)) == Set(expected) else {
            throw NivoPersonalBackupError.invalidPackage
        }
        for entry in entries {
            try NivoRoutineBackup.validatePath(entry.path)
            if entry.isSkipped { continue }
            if entry.isDirectory {
                guard entry.size == 0, entry.digest == nil else { throw NivoPersonalBackupError.invalidPackage }
            } else {
                guard let digest = entry.digest, digest.utf8.count == 64,
                      digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                      entry.size >= 0 else { throw NivoPersonalBackupError.invalidPackage }
            }
        }
    }

    private func destination(_ relative: String, isDirectory: Bool) throws -> URL? {
        let components = relative.split(separator: "/").map(String.init)
        var directory = home
        for name in isDirectory ? components : Array(components.dropLast()) {
            directory.appendPathComponent(name, isDirectory: true)
            if let kind = try nodeType(directory), kind != .typeDirectory { return nil }
            try requireDirectory(directory)
        }
        return isDirectory ? directory : directory.appendingPathComponent(components.last!)
    }

    private func verifiedBlob(_ entry: Entry, root: URL) throws -> URL {
        guard let digest = entry.digest else { throw NivoPersonalBackupError.invalidPackage }
        var source = root
        for component in ["blobs", String(digest.prefix(2))] {
            guard try nodeType(source) == .typeDirectory else { throw NivoPersonalBackupError.invalidPackage }
            source.appendPathComponent(component, isDirectory: true)
        }
        guard try nodeType(source) == .typeDirectory else { throw NivoPersonalBackupError.invalidPackage }
        source.appendPathComponent(digest)
        try verifyContent(source, entry: entry)
        return source
    }

    private func verifyContent(_ file: URL, entry: Entry) throws {
        let attributes = try manager.attributesOfItem(atPath: file.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.size] as? NSNumber)?.int64Value == entry.size,
              try Self.digest(file) == entry.digest else { throw NivoPersonalBackupError.invalidPackage }
    }

    private func install(_ source: URL, entry: Entry, target: URL,
                         afterStaging: (String) throws -> Void) throws {
        let staged = target.deletingLastPathComponent().appendingPathComponent(".restore-file-" + UUID().uuidString)
        defer { try? manager.removeItem(at: staged) }
        try manager.copyItem(at: source, to: staged)
        // 校验副本，避免读取摘要与复制之间文件发生变化而落入正式路径。
        try verifyContent(staged, entry: entry)
        try afterStaging(entry.path)
        try manager.moveItem(at: staged, to: target)
    }

    private func requireDirectory(_ url: URL) throws {
        if let kind = try nodeType(url) {
            guard kind == .typeDirectory else { throw NivoPersonalBackupError.invalidPackage }
        } else { try manager.createDirectory(at: url, withIntermediateDirectories: false) }
    }

    private func nodeType(_ url: URL) throws -> FileAttributeType? {
        do { return try manager.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType }
        catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile { return nil }
    }
}
