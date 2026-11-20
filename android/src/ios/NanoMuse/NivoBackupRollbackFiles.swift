import Foundation

/// 恢复前完整核对快照布局，缺少路径标记不能被解释为可以清理的空快照。
enum NivoBackupRollbackFiles {
    static let fileSidecarSuffix = ".live-path-of"
    static let absentSidecarSuffix = ".absent-path-of"
    static let sqliteSidecarSuffix = ".sqlite-path-of"

    enum Kind: Sendable { case directory, file, absent, sqlite }

    struct Entry: Sendable {
        let kind: Kind
        let saved: URL
        let live: URL
    }

    /// 新日志只匹配自己的runId；旧日志存在多个候选时拒绝猜测恢复来源。
    static func recoveryRoot(marker: NivoBackupRecoveryState.Marker, roots: [URL]) throws -> URL {
        if let runId = marker.runId {
            guard let root = roots.first(where: { $0.lastPathComponent == "rollback-" + runId }) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return root
        }
        guard roots.count == 1, let root = roots.first else { throw CocoaError(.fileReadCorruptFile) }
        return root
    }

    /// 完整解析成功后才返回任何恢复动作，避免发现尾部损坏时前面的目录已被覆盖。
    static func entries(in root: URL, expectedNames: [String]?) throws -> [Entry] {
        try requireType(root, .typeDirectory)
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        let companions = try sqliteCompanions(in: root, names: names, registered: expectedNames ?? names)
        let companionNames = Set(companions.values.flatMap { $0 })
        if let expectedNames {
            // 旧版只读校验可能生成WAL辅助文件；清单原有项仍必须齐全，只允许已登记数据库的配对文件。
            guard Set(expectedNames).isSubset(of: Set(names)),
                  Set(names).subtracting(expectedNames).isSubset(of: companionNames) else {
                throw CocoaError(.fileReadCorruptFile)
            }
        } else if names.isEmpty { throw CocoaError(.fileReadCorruptFile) }
        var result: [Entry] = []
        var consumed = Set<String>()
        for name in names where !consumed.contains(name) {
            guard NivoBackupRecoveryState.isSnapshotName(name) else { throw CocoaError(.fileReadCorruptFile) }
            if companionNames.contains(name) { continue }
            let saved = root.appendingPathComponent(name)
            if name.hasSuffix(absentSidecarSuffix) {
                result.append(Entry(kind: .absent, saved: saved, live: try liveURL(from: saved, root: root)))
                consumed.insert(name)
            } else if name.hasSuffix(fileSidecarSuffix) || name.hasSuffix(sqliteSidecarSuffix) {
                let isDatabase = name.hasSuffix(sqliteSidecarSuffix)
                let suffix = isDatabase ? sqliteSidecarSuffix : fileSidecarSuffix
                let payloadName = String(name.dropLast(suffix.count))
                guard !payloadName.isEmpty, names.contains(payloadName), !consumed.contains(payloadName) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                let payload = root.appendingPathComponent(payloadName)
                try requireType(payload, .typeRegular)
                if isDatabase {
                    // 让SQLite读取真实WAL中已提交的内容，不能删除辅助文件或使用immutable忽略WAL。
                    try NivoSQLiteSnapshot.validate(payload)
                    consumed.formUnion(companions[payloadName] ?? [])
                }
                result.append(Entry(kind: isDatabase ? .sqlite : .file, saved: payload, live: try liveURL(from: saved, root: root)))
                consumed.formUnion([name, payloadName])
            } else if names.contains(name + fileSidecarSuffix) || names.contains(name + sqliteSidecarSuffix) {
                // 普通文件交给其sidecar分支统一校验，不能被当成缺少.live-path的目录跳过。
                continue
            } else {
                try requireType(saved, .typeDirectory)
                result.append(Entry(kind: .directory, saved: saved,
                    live: try liveURL(from: saved.appendingPathComponent(".live-path"), root: root)))
                consumed.insert(name)
            }
        }
        guard consumed == Set(names), Set(result.map { $0.live.standardizedFileURL.path }).count == result.count else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return result
    }

    /// 辅助文件仅属于同一清单内的SQLite载荷与路径标记，目录、链接和无关文件仍拒绝。
    private static func sqliteCompanions(in root: URL, names: [String], registered: [String]) throws -> [String: Set<String>] {
        var result: [String: Set<String>] = [:]
        let registeredNames = Set(registered)
        let actualNames = Set(names)
        for sidecar in registered where sidecar.hasSuffix(sqliteSidecarSuffix) {
            let payload = String(sidecar.dropLast(sqliteSidecarSuffix.count))
            guard !payload.isEmpty, registeredNames.contains(payload), actualNames.contains(sidecar),
                  actualNames.contains(payload), NivoBackupRecoveryState.isSnapshotName(payload) else { continue }
            let candidates = actualNames.intersection([payload + "-wal", payload + "-shm"])
            guard !candidates.isEmpty else { continue }
            try requireType(root.appendingPathComponent(sidecar), .typeRegular)
            guard try NivoSQLiteSnapshot.usesWAL(root.appendingPathComponent(payload)) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            for name in candidates { try requireType(root.appendingPathComponent(name), .typeRegular) }
            result[payload] = candidates
        }
        return result
    }

    /// 日志删除失败时保持唯一回滚副本；快照清理失败向调用者返回，供后续孤立目录清理重试。
    static func finish(marker: URL, root: URL,
                       remove: (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }) throws {
        guard root.deletingLastPathComponent().standardizedFileURL == marker.deletingLastPathComponent().standardizedFileURL,
              root.lastPathComponent.hasPrefix("rollback-") || root.lastPathComponent == "rollback" else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try remove(marker)
        try remove(root)
    }

    /// 不跟随路径标记的符号链接，也不允许恢复目标包含回滚目录自身。
    private static func liveURL(from sidecar: URL, root: URL) throws -> URL {
        try requireType(sidecar, .typeRegular)
        let values = try sidecar.resourceValues(forKeys: [.fileSizeKey])
        guard let size = values.fileSize, size > 0, size <= 16 * 1_024 else { throw CocoaError(.fileReadCorruptFile) }
        let path = try String(contentsOf: sidecar, encoding: .utf8)
        guard (path as NSString).isAbsolutePath, !path.contains("\0") else { throw CocoaError(.fileReadCorruptFile) }
        let live = URL(fileURLWithPath: path).standardizedFileURL
        let rootParts = canonicalComponents(root)
        let liveParts = canonicalComponents(live)
        guard !rootParts.starts(with: liveParts), !liveParts.starts(with: rootParts) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return live
    }

    /// 不存在的目标先解析最近的现存祖先，避免目录联接与Windows短路径漏过边界检查。
    private static func canonicalComponents(_ url: URL) -> [String] {
        var ancestor = url.standardizedFileURL
        var suffix: [String] = []
        while !FileManager.default.fileExists(atPath: ancestor.path), ancestor.pathComponents.count > 1 {
            suffix.insert(ancestor.lastPathComponent, at: 0)
            ancestor.deleteLastPathComponent()
        }
        let parts = ancestor.resolvingSymlinksInPath().pathComponents + suffix
        #if os(Windows)
        return parts.map { $0.lowercased() }
        #else
        return parts
        #endif
    }

    /// attributesOfItem保留符号链接类型，不能把链接后的目录当作本次快照。
    private static func requireType(_ url: URL, _ expected: FileAttributeType) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == expected else { throw CocoaError(.fileReadCorruptFile) }
    }
}
