import Foundation

/// 将旧版本目录合并到当前存储；只移动缺少的项目，同名内容继续留在旧位置。
enum NivoLegacyStorageMigration {
    /// 必须在默认SOUL、预置资料和SkillStore首次初始化之前调用；失败可原地重试。
    static func migrate(layout: NivoStorageLayout, fileManager: FileManager = .default) throws {
        let library = layout.localContainer.deletingLastPathComponent()
        for name in ["shared", "memory", "skills"] {
            try merge(
                source: library.appendingPathComponent("MinisChat/" + name, isDirectory: true),
                destination: layout.applicationFiles.appendingPathComponent(name, isDirectory: true),
                fileManager: fileManager
            )
        }
        if let shared = layout.sharedContainer {
            try merge(
                source: shared.appendingPathComponent("MinisShared", isDirectory: true),
                destination: layout.applicationFiles.appendingPathComponent("shared", isDirectory: true),
                fileManager: fileManager
            )
        }
    }

    /// 递归合并真实目录，符号链接作为文件处理，不进入其指向的外部目录。
    private static func merge(source: URL, destination: URL, fileManager: FileManager) throws {
        guard let sourceType = try entryType(source, fileManager: fileManager) else { return }
        guard sourceType == .typeDirectory else { throw CocoaError(.fileReadUnknown) }
        if let destinationType = try entryType(destination, fileManager: fileManager) {
            guard destinationType == .typeDirectory else { throw CocoaError(.fileWriteFileExists) }
        } else {
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        }
        let items = try fileManager.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
        for item in items {
            let target = destination.appendingPathComponent(item.lastPathComponent)
            let targetType = try entryType(target, fileManager: fileManager)
            if targetType == nil {
                try fileManager.moveItem(at: item, to: target)
            } else if targetType == .typeDirectory,
                      try entryType(item, fileManager: fileManager) == .typeDirectory {
                try merge(source: item, destination: target, fileManager: fileManager)
            }
        }
        // 枚举失败必须上抛，不能把无法读取误认为空目录。
        if try fileManager.contentsOfDirectory(atPath: source.path).isEmpty {
            try fileManager.removeItem(at: source)
        }
    }

    /// 权限错误不能当成目录不存在；attributes不会进入符号链接目标。
    private static func entryType(_ url: URL, fileManager: FileManager) throws -> FileAttributeType? {
        do {
            guard let type = try fileManager.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType else {
                throw CocoaError(.fileReadUnknown)
            }
            return type
        } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            return nil
        }
    }
}
