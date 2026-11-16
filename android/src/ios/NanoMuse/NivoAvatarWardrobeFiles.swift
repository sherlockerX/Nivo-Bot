import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// 衣柜只归档生成形象的固定文件，不移动用户单独上传的视频。
struct NivoAvatarWardrobeFiles: Sendable {
    struct Pet: Codable, Identifiable, Sendable {
        var id: String
        var description: String
        var savedAt: Date
    }

    let root: URL
    // 文件管理器不作为Sendable值的一部分保存。
    private var manager: FileManager { .default }
    private static let names = ["idle.png", "working.png", "waiting.png", "happy.png", "error.png", "meta.json", "emoji.json"]
        + ["idle", "working", "waiting", "happy", "error"].map { "motion/" + $0 + ".mp4" }
    private var pets: URL { root.appendingPathComponent("pets", isDirectory: true) }
    private var rollback: URL { root.appendingPathComponent(".wardrobe-rollback", isDirectory: true) }

    /// 文件事务使用同一规范化根路径，避免目录联接两端被Foundation误判成跨卷移动。
    init(root: URL) {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
    }

    /// 上次切换未提交时恢复完整旧形象，失败保留回滚副本等待重试。
    func recover() throws {
        try recoverArchives()
        guard manager.fileExists(atPath: rollback.path) else { return }
        try installFiles(from: rollback)
        try manager.removeItem(at: rollback)
    }

    /// 更新同一存档时意外退出，旧目录仍可按元数据找回，不能当作缓存删除。
    private func recoverArchives() throws {
        guard manager.fileExists(atPath: pets.path) else { return }
        let folders = try manager.contentsOfDirectory(at: pets, includingPropertiesForKeys: nil)
        for folder in folders where folder.lastPathComponent.hasPrefix(".old-") {
            let metadata = try JSONDecoder().decode(Pet.self, from: Data(contentsOf: folder.appendingPathComponent("pet.json")))
            let destination = try petDirectory(metadata.id)
            if manager.fileExists(atPath: destination.path) { try manager.removeItem(at: folder) }
            else { try manager.moveItem(at: folder, to: destination) }
        }
    }

    /// 每次归档先写临时目录，完整副本就绪后才发布到衣柜。
    @discardableResult func archiveCurrent() throws -> String? {
        guard manager.fileExists(atPath: root.appendingPathComponent("idle.png").path) else { return nil }
        let bytes = try Data(contentsOf: root.appendingPathComponent("idle.png"))
        let identifier = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let destination = try petDirectory(identifier)
        if manager.fileExists(atPath: destination.path) {
            // 已有相同形象仍可能补齐了姿态或动态片段，保留原存档直到新副本完成。
            let staged = try stage(from: root)
            defer { try? manager.removeItem(at: staged) }
            let previous = try Data(contentsOf: destination.appendingPathComponent("pet.json"))
            try previous.write(to: staged.appendingPathComponent("pet.json"), options: .atomic)
            let old = pets.appendingPathComponent(".old-" + UUID().uuidString)
            try manager.moveItem(at: destination, to: old)
            do { try manager.moveItem(at: staged, to: destination) }
            catch { try manager.moveItem(at: old, to: destination); throw error }
            try? manager.removeItem(at: old)
            return identifier
        }
        let staged = try stage(from: root)
        defer { try? manager.removeItem(at: staged) }
        let description = try currentDescription()
        try JSONEncoder().encode(Pet(id: identifier, description: description, savedAt: Date()))
            .write(to: staged.appendingPathComponent("pet.json"), options: .atomic)
        try manager.createDirectory(at: pets, withIntermediateDirectories: true)
        try manager.moveItem(at: staged, to: destination)
        return identifier
    }

    /// 更换形象时先保留当前形象与独立回滚副本，再替换固定文件。
    func replace(with files: [String: Data]) throws {
        guard Set(files.keys).isSubset(of: Set(Self.names)) else { throw NivoLifeError.invalidField("avatar_file") }
        let staged = root.appendingPathComponent(".wardrobe-stage-" + UUID().uuidString)
        try manager.createDirectory(at: staged, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: staged) }
        for (name, data) in files {
            let path = staged.appendingPathComponent(name)
            try manager.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: path, options: .atomic)
        }
        try switchFiles(from: staged)
    }

    /// 衣柜切换复用已有图片和片段，整个流程不调用模型。
    func wear(_ identifier: String) throws {
        guard identifier != "dragon" else { try replace(with: [:]); return }
        let selected = try petDirectory(identifier)
        guard manager.fileExists(atPath: selected.appendingPathComponent("idle.png").path) else {
            throw NivoLifeError.notFound("avatar")
        }
        try switchFiles(from: selected)
    }

    /// 只枚举完整存档，临时目录不会显示为可选择的形象。
    func list() throws -> [Pet] {
        guard manager.fileExists(atPath: pets.path) else { return [] }
        return try manager.contentsOfDirectory(at: pets, includingPropertiesForKeys: nil).compactMap { folder in
            guard folder.lastPathComponent.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else { return nil }
            let pet = try JSONDecoder().decode(Pet.self, from: Data(contentsOf: folder.appendingPathComponent("pet.json")))
            guard pet.id == folder.lastPathComponent else { throw NivoLifeError.corruptStore }
            return pet
        }.sorted { $0.savedAt > $1.savedAt }
    }

    /// 删除衣柜副本不删除当前正在使用的形象。
    func remove(_ identifier: String) throws { try manager.removeItem(at: petDirectory(identifier)) }

    /// 缩略图数据在工作线程读取，界面不遍历磁盘目录。
    func thumbnail(_ identifier: String) throws -> Data {
        try Data(contentsOf: petDirectory(identifier).appendingPathComponent("idle.png"))
    }

    private func switchFiles(from source: URL) throws {
        try recover()
        _ = try archiveCurrent()
        let previous = try stage(from: root)
        try manager.moveItem(at: previous, to: rollback)
        do {
            try installFiles(from: source)
            // 删除回滚副本是提交标记，失败则恢复原形象。
            try manager.removeItem(at: rollback)
        } catch {
            try recover()
            throw error
        }
    }

    private func stage(from source: URL) throws -> URL {
        let folder = root.appendingPathComponent(".wardrobe-stage-" + UUID().uuidString)
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        do { try copyFiles(from: source, to: folder) }
        catch { try? manager.removeItem(at: folder); throw error }
        return folder
    }

    private func installFiles(from source: URL) throws {
        for name in Self.names {
            let destination = root.appendingPathComponent(name)
            if manager.fileExists(atPath: destination.path) { try manager.removeItem(at: destination) }
        }
        try copyFiles(from: source, to: root)
    }

    private func copyFiles(from source: URL, to destination: URL) throws {
        for name in Self.names {
            let original = source.appendingPathComponent(name)
            guard manager.fileExists(atPath: original.path) else { continue }
            let values = try original.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { throw NivoLifeError.corruptStore }
            let target = destination.appendingPathComponent(name)
            try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            // 后续图片与片段均以原子替换写入，硬链接可省去大视频的重复复制。
            do { try manager.linkItem(at: original, to: target) }
            catch { try manager.copyItem(at: original, to: target) }
        }
    }

    private func currentDescription() throws -> String {
        let path = root.appendingPathComponent("meta.json")
        guard manager.fileExists(atPath: path.path) else { return "" }
        guard let metadata = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any] else {
            throw NivoLifeError.corruptStore
        }
        return metadata["description"] as? String ?? ""
    }

    private func petDirectory(_ identifier: String) throws -> URL {
        guard identifier.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
            throw NivoLifeError.invalidField("avatar_id")
        }
        // 先解析现存父目录，再拼接尚不存在的存档；否则Windows短路径可能与已展开的父路径不同。
        let parent = pets.standardizedFileURL.resolvingSymlinksInPath()
        let directory = parent.appendingPathComponent(identifier, isDirectory: true)
        guard directory.resolvingSymlinksInPath().deletingLastPathComponent().pathComponents == parent.pathComponents else {
            throw NivoLifeError.invalidField("avatar_path")
        }
        return directory
    }
}
