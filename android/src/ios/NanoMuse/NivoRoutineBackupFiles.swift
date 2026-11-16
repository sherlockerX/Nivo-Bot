import Foundation

/// 任务文件传输只读当前账户目录，将通用备份索引转换为home的受限文件入口。
enum NivoRoutineBackupFiles {
    static let prefix = "personal_data/routine-home/"
    static var routineFile: URL { NanoMuseDirs.root.appendingPathComponent("routines.json") }
    static var settingsFile: URL { NanoMuseDirs.root.appendingPathComponent("routine-settings.json") }
    typealias Restored = NivoRoutineHomeFiles.Restored

    /// 脚本与资料逐文件进入内容寻址blob，符号链接和特殊节点只记录未包含状态。
    static func export(blobs: BackupBlobStore, index: BackupFileIndexWriter) throws -> (NivoRoutineBackup, Int, Int64) {
        let home = try NivoScheduledHome.ensure()
        let nodes = try NivoRoutineHomeFiles(home: home).scan()
        var files = 0
        var bytes: Int64 = 0
        for node in nodes {
            let path = prefix + node.path
            switch node.kind {
            case .typeDirectory:
                index.write(.directory(path: path, category: .personalData))
            case .typeRegular:
                switch try blobs.addFile(at: node.url, logicalPath: path) {
                case .stored(let digest, let size), .duplicate(let digest, let size):
                    index.write(.file(path: path, size: size, sha256: digest, category: .personalData))
                    files += 1
                    bytes += size
                case .skippedTooLarge(let size):
                    index.write(.sizeSkipped(path: path, size: size, category: .personalData))
                }
            default:
                index.write(BackupFileIndexEntry(path: path, size: 0,
                    category: BackupCategory.personalData.rawValue, skipped: "unreadable"))
            }
        }
        let document = NivoRoutineBackup(routines: try NivoRoutineArchive.read(routineFile),
            settings: try NivoRoutineArchive.readSettings(settingsFile), homePaths: nodes.map(\.path))
        try document.validate()
        return (document, files, bytes)
    }

    /// 文件冲突保留本机内容并返回路径；内容损坏或路径越界则让外层回滚整个类别。
    static func restore(_ document: NivoRoutineBackup, root: URL, entries: [BackupFileIndexEntry]) throws -> Restored {
        try document.validate()
        let relevant = entries.filter { $0.category == BackupCategory.personalData.rawValue && $0.path.hasPrefix(prefix) }
        let files = relevant.map {
            NivoRoutineHomeFiles.Entry(path: String($0.path.dropFirst(prefix.count)), size: $0.size,
                digest: $0.sha256, isDirectory: $0.isDirectory == true, isSkipped: $0.skipped != nil)
        }
        return try NivoRoutineHomeFiles(home: NivoScheduledHome.ensure()).restore(files,
            expected: document.homePaths, packageRoot: root)
    }
}
