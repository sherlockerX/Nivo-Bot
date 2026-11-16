import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 碎片照片仅在设备内缩图和存储，不向模型暴露文件内容或EXIF信息。
actor NivoMosaicMediaStore {
    static let shared = NivoMosaicMediaStore(directory: NanoMuseDirs.root.appendingPathComponent("mosaic-media"))
    private let directory: URL
    private var activeScope: NivoLifeScope?

    init(directory: URL) { self.directory = directory }

    /// 账户宿主发放代次凭证，页面只能使用自己打开时的凭证。
    func bind(scope: NivoLifeScope) { activeScope = scope }

    /// 退出即时拒绝正在导入的旧页面。
    func revoke() { activeScope = nil }

    /// 限制输入体积并重新编码为JPEG；保留的文件名完全由应用生成。
    func add(_ data: Data, scope: NivoLifeScope) throws -> String {
        try check(scope)
        guard data.count <= 32 * 1_024 * 1_024 else { throw NivoFocusBackgroundError.tooLarge }
        let prepared = try prepare(data, pixels: 2_400)
        let name = UUID().uuidString + ".jpg"
        try FileManager.default.createDirectory(at: folder(scope.ownerKey), withIntermediateDirectories: true)
        try prepared.write(to: file(name, owner: scope.ownerKey), options: .atomic)
        return name
    }

    /// 缩略图在actor中生成，滚动列表不会在主线程反复解码原图。
    func imageData(path: String, scope: NivoLifeScope, thumbnail: Bool) throws -> Data {
        try check(scope)
        let data = try Data(contentsOf: file(path, owner: scope.ownerKey))
        return thumbnail ? try prepare(data, pixels: 640) : data
    }

    /// 保存前确认照片已经落盘；缺失时保留草稿并提示重新选择。
    func exists(path: String, scope: NivoLifeScope) throws -> Bool {
        try check(scope)
        return FileManager.default.fileExists(atPath: try file(path, owner: scope.ownerKey).path)
    }

    /// 只清理未被任何记录或草稿引用且超过一天的孤立文件。
    func sweep(references: Set<String>, scope: NivoLifeScope, now: Date = Date()) throws {
        try check(scope)
        let target = folder(scope.ownerKey)
        guard FileManager.default.fileExists(atPath: target.path) else { return }
        for url in try FileManager.default.contentsOfDirectory(at: target, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]) {
            guard !references.contains(url.lastPathComponent), (try? NivoMosaicRules.validateMediaPath(url.lastPathComponent)) != nil else { continue }
            let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values.isRegularFile == true, let modified = values.contentModificationDate,
                  now.timeIntervalSince(modified) >= 86_400 else { continue }
            try FileManager.default.removeItem(at: url)
        }
    }

    /// 账户删除的根路径固定为哈希目录，不能由图片文件名决定。
    func removeAccount(ownerKey: String) throws {
        if activeScope?.ownerKey == ownerKey { activeScope = nil }
        let target = folder(ownerKey).deletingLastPathComponent()
        guard target.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath().pathComponents == directory.standardizedFileURL.resolvingSymlinksInPath().pathComponents else {
            throw NivoLifeError.invalidField("account_path")
        }
        if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
    }

    private func check(_ scope: NivoLifeScope) throws {
        guard activeScope == scope else { throw NivoLifeError.accountChanged }
    }

    private func folder(_ owner: String) -> URL {
        directory.appendingPathComponent(NivoFocusPreferences.ownerHash(owner), isDirectory: true).appendingPathComponent("images", isDirectory: true)
    }

    private func file(_ name: String, owner: String) throws -> URL {
        try NivoMosaicRules.validateMediaPath(name)
        return folder(owner).appendingPathComponent(name)
    }

    private func prepare(_ data: Data, pixels: Int) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: pixels,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { throw NivoFocusBackgroundError.unreadable }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw NivoFocusBackgroundError.unreadable
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.88] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw NivoFocusBackgroundError.unreadable }
        return output as Data
    }
}
