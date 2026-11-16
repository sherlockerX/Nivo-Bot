import Foundation

/// 个人数据单独标记版本，图片内容通过现有备份blob索引传递。
struct NivoPersonalBackupDocument: Codable, Sendable {
    var version = 1
    var life: NivoLifeState
    var coach: NivoCoachState
    var archives: [NivoCoachArchiveEntry]
    var backgrounds: [NivoFocusBackground]
    var selectedBackground: String
    var routines: NivoRoutineBackup?
}

/// 个人备份只接受固定文件布局，绝不从备份包提供的账户路径推导写入位置。
enum NivoPersonalBackupFiles {
    static let documentName = "personal-data.json"
    static let maximumDocumentBytes = 128 * 1_024 * 1_024

    /// 导出当前账户引用的照片，孤立缓存和其他账户不会进入备份。
    static func export(lease: NivoPersonalBackupLease, dataDir: URL,
                       blobStore: BackupBlobStore, fileIndex: BackupFileIndexWriter) throws -> BackupManifest.CategoryStat {
        let paths = directories(owner: lease.ownerKey)
        let backgrounds = try readBackgrounds(paths[0].appendingPathComponent("backgrounds/index.json"))
        let routineExport = try NivoRoutineBackupFiles.export(blobs: blobStore, index: fileIndex)
        let document = NivoPersonalBackupDocument(life: lease.portableLife, coach: lease.coach,
            archives: lease.archives, backgrounds: backgrounds, selectedBackground: lease.selectedBackground, routines: routineExport.0)
        let data = try encode(document)
        try data.write(to: dataDir.appendingPathComponent(documentName), options: .atomic)
        var bytes = Int64(data.count) + routineExport.2
        var files = routineExport.1
        let images = mediaNames(lease.portableLife)
        for name in images.sorted() {
            try appendImage(paths[2].appendingPathComponent("images").appendingPathComponent(name),
                path: "personal_data/mosaic/" + name, blobs: blobStore, index: fileIndex, bytes: &bytes, files: &files)
        }
        for background in backgrounds {
            try appendImage(paths[0].appendingPathComponent("backgrounds/" + background.id + ".jpg"),
                path: "personal_data/backgrounds/" + background.id + ".jpg", blobs: blobStore,
                index: fileIndex, bytes: &bytes, files: &files)
        }
        return BackupManifest.CategoryStat(entries: recordCount(document), bytes: bytes, encrypted: false, files: files)
    }

    /// 读取前检查文件大小，再验证完整模型，坏文件不会进入合并阶段。
    static func read(root: URL) throws -> NivoPersonalBackupDocument {
        let file = root.appendingPathComponent("data").appendingPathComponent(documentName)
        let values = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let bytes = values.fileSize, bytes <= maximumDocumentBytes else { throw NivoPersonalBackupError.invalidPackage }
        let document = try JSONDecoder().decode(NivoPersonalBackupDocument.self, from: Data(contentsOf: file))
        guard document.version == 1 else { throw NivoLifeError.unsupportedVersion(document.version) }
        try NivoLifeValidation.validate(document.life, owner: document.life.ownerKey)
        try NivoCoachV2Store.validate(document.coach)
        try validateBackgrounds(document.backgrounds)
        try document.routines?.validate()
        guard document.archives.count <= 10_000 else { throw NivoPersonalBackupError.invalidPackage }
        return document
    }

    /// 三个账户目录均记录回滚快照，原来不存在的目录用空快照表示。
    static func snapshot(owner: String, staging: URL) throws -> BackupRollbackSnapshot {
        let fm = FileManager.default
        var snapshot = BackupRollbackSnapshot(category: .personalData)
        for (index, live) in directories(owner: owner).enumerated() {
            let saved = staging.appendingPathComponent("personal_data-\(index)", isDirectory: true)
            if fm.fileExists(atPath: live.path) { try fm.copyItem(at: live, to: saved) }
            else { try fm.createDirectory(at: saved, withIntermediateDirectories: true) }
            try Data(live.path.utf8).write(to: saved.appendingPathComponent(".live-path"), options: .atomic)
            snapshot.directories.append((live, saved))
        }
        let home = NivoScheduledHome.directory
        let savedHome = staging.appendingPathComponent("personal_data-routine-home", isDirectory: true)
        if fm.fileExists(atPath: home.path) { try fm.copyItem(at: home, to: savedHome) }
        else { try fm.createDirectory(at: savedHome, withIntermediateDirectories: true) }
        try Data(home.path.utf8).write(to: savedHome.appendingPathComponent(".live-path"), options: .atomic)
        snapshot.directories.append((home, savedHome))
        for name in ["routines.json", "routine-settings.json", "routine-script-approvals.json"] {
            let live = NanoMuseDirs.root.appendingPathComponent(name)
            let saved = staging.appendingPathComponent("personal_data-" + name)
            if fm.fileExists(atPath: live.path) {
                try fm.copyItem(at: live, to: saved)
                try Data(live.path.utf8).write(to: saved.appendingPathExtension("live-path-of"), options: .atomic)
                snapshot.files.append((live, saved))
            } else {
                try Data(live.path.utf8).write(to: saved.appendingPathExtension("absent-path-of"), options: .atomic)
                snapshot.absentFiles.append(live)
            }
        }
        return snapshot
    }

    /// 分别定位生活、教练和碎片媒体目录，所有路径由当前账户哈希生成。
    static func directories(owner: String) -> [URL] {
        let hash = NivoFocusPreferences.ownerHash(owner)
        return ["life", "coach-v2", "mosaic-media"].map {
            NanoMuseDirs.root.appendingPathComponent($0, isDirectory: true).appendingPathComponent(hash, isDirectory: true)
        }
    }

    /// 合并图片前保留同名本机文件，内容冲突必须由用户重新选择备份，不能覆盖照片。
    static func restoreImages(document: NivoPersonalBackupDocument, root: URL,
                              index: [BackupFileIndexEntry], owner: String) throws -> (written: Int, bytes: Int64, missing: Set<String>) {
        let expected = Set(mediaNames(document.life).map { "personal_data/mosaic/" + $0 })
            .union(document.backgrounds.map { "personal_data/backgrounds/" + $0.id + ".jpg" })
        let relevant = index.filter {
            $0.category == BackupCategory.personalData.rawValue && $0.isDirectory != true
                && !(document.routines != nil && $0.path.hasPrefix(NivoRoutineBackupFiles.prefix))
        }
        guard relevant.count <= 20_000, Set(relevant.map(\.path)).count == relevant.count,
              relevant.allSatisfy({ expected.contains($0.path) }) else { throw NivoPersonalBackupError.invalidPackage }
        let lookup = Dictionary(uniqueKeysWithValues: relevant.map { ($0.path, $0) })
        var missing = Set<String>()
        var written = 0
        var bytes: Int64 = 0
        for path in expected.sorted() {
            guard let entry = lookup[path] else { throw NivoPersonalBackupError.invalidPackage }
            if entry.skipped != nil { missing.insert(path); continue }
            let result = try restoreImage(entry, root: root, owner: owner)
            if result { written += 1; bytes += entry.size }
        }
        return (written, bytes, missing)
    }

    /// 照片缺失只清理备份副本中的引用，本机已有记录由合并规则保留。
    static func droppingMissingImages(_ document: NivoPersonalBackupDocument, missing: Set<String>,
                                      local: NivoLifeState? = nil) -> NivoPersonalBackupDocument {
        var result = document
        if var mosaic = result.life.mosaic {
            for index in mosaic.entries.indices {
                if let name = mosaic.entries[index].mediaPath, missing.contains("personal_data/mosaic/" + name),
                   local?.mosaic?.entries.contains(where: { $0.id == mosaic.entries[index].id && $0.mediaPath == name }) != true {
                    mosaic.entries[index].mediaPath = nil
                }
            }
            for index in mosaic.drafts.indices {
                if let name = mosaic.drafts[index].mediaPath, missing.contains("personal_data/mosaic/" + name),
                   local?.mosaic?.drafts.contains(where: { $0.id == mosaic.drafts[index].id && $0.mediaPath == name }) != true {
                    mosaic.drafts[index].mediaPath = nil
                }
            }
            result.life.mosaic = mosaic
        }
        result.backgrounds.removeAll { missing.contains("personal_data/backgrounds/" + $0.id + ".jpg") }
        return result
    }

    /// 背景目录保留本机选择与已有照片，合并后仍遵循24张上限。
    static func mergeBackgrounds(_ incoming: [NivoFocusBackground], owner: String) throws -> [NivoFocusBackground] {
        let target = directories(owner: owner)[0].appendingPathComponent("backgrounds", isDirectory: true)
        let local = try readBackgrounds(target.appendingPathComponent("index.json"))
        let identifiers = Set(local.map(\.id))
        let merged = local + incoming.filter { !identifiers.contains($0.id) }
        try validateBackgrounds(merged)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try JSONEncoder().encode(merged).write(to: target.appendingPathComponent("index.json"), options: .atomic)
        return merged
    }

    static func recordCount(_ document: NivoPersonalBackupDocument) -> Int {
        document.life.tasks.count + document.life.focusSessions.count + (document.life.mosaic?.entries.count ?? 0)
            + document.coach.sessions.count + document.coach.drafts.count + (document.routines?.routines.count ?? 0)
    }

    private static func restoreImage(_ entry: BackupFileIndexEntry, root: URL, owner: String) throws -> Bool {
        guard let digest = entry.sha256, digest.count == 64,
              digest.allSatisfy({ $0.isHexDigit && !$0.isUppercase }), entry.size >= 0,
              entry.size <= 32 * 1_024 * 1_024 else { throw NivoPersonalBackupError.invalidPackage }
        let source = root.appendingPathComponent(BackupBlobStore.packagePath(for: digest))
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              values.fileSize == Int(entry.size), try BackupBlobStore.sha256OfFile(at: source) == digest else {
            throw NivoPersonalBackupError.invalidPackage
        }
        let parts = entry.path.split(separator: "/").map(String.init)
        guard parts.count == 3, parts[0] == "personal_data" else { throw NivoPersonalBackupError.invalidPackage }
        try NivoMosaicRules.validateMediaPath(parts[2])
        let paths = directories(owner: owner)
        let folder = parts[1] == "mosaic" ? paths[2].appendingPathComponent("images") : paths[0].appendingPathComponent("backgrounds")
        let destination = folder.appendingPathComponent(parts[2])
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            guard try BackupBlobStore.sha256OfFile(at: destination) == digest else { throw NivoLifeError.operationConflict }
            return false
        }
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(contentsOf: source).write(to: destination, options: .atomic)
        return true
    }

    private static func appendImage(_ source: URL, path: String, blobs: BackupBlobStore,
                                    index: BackupFileIndexWriter, bytes: inout Int64, files: inout Int) throws {
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw NivoPersonalBackupError.invalidPackage }
        switch try blobs.addFile(at: source, logicalPath: path) {
        case .stored(let digest, let size), .duplicate(let digest, let size):
            index.write(.file(path: path, size: size, sha256: digest, category: .personalData))
            bytes += size
            files += 1
        case .skippedTooLarge(let size):
            index.write(.sizeSkipped(path: path, size: size, category: .personalData))
        }
    }

    private static func mediaNames(_ life: NivoLifeState) -> Set<String> {
        Set((life.mosaic?.entries.compactMap(\.mediaPath) ?? []) + (life.mosaic?.drafts.compactMap(\.mediaPath) ?? []))
    }

    /// 断点续传只能继续同一账户，避免把另一账户的缓存档案混入新导出。
    static func validateResume(root: URL, owner: String) throws {
        let document = try read(root: root)
        guard document.life.ownerKey == owner else { throw NivoLifeError.accountChanged }
    }

    private static func readBackgrounds(_ file: URL) throws -> [NivoFocusBackground] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        let data = try Data(contentsOf: file)
        guard data.count <= 64 * 1_024 else { throw NivoPersonalBackupError.invalidPackage }
        let values = try JSONDecoder().decode([NivoFocusBackground].self, from: data)
        try validateBackgrounds(values)
        return values
    }

    private static func validateBackgrounds(_ values: [NivoFocusBackground]) throws {
        guard values.count <= 24, Set(values.map(\.id)).count == values.count,
              values.allSatisfy({ UUID(uuidString: $0.id) != nil && $0.createdAt.timeIntervalSince1970.isFinite }) else {
            throw NivoPersonalBackupError.invalidPackage
        }
    }

    private static func encode(_ value: NivoPersonalBackupDocument) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        guard data.count <= maximumDocumentBytes else { throw NivoPersonalBackupError.invalidPackage }
        return data
    }
}
