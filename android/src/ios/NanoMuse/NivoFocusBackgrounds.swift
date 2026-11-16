import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 本机导入的背景只有随机文件名和创建时间，不保留照片位置或其他EXIF信息。
struct NivoFocusBackground: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var createdAt: Date
}

/// 背景按账户保存，导入等待期间切换账户会撤销原凭证。
actor NivoFocusBackgroundStore {
    static let shared = NivoFocusBackgroundStore()
    private let directory: URL
    private let maximumCount = 24
    private var activeScope: NivoLifeScope?

    init(directory: URL = NanoMuseDirs.root.appendingPathComponent("life", isDirectory: true)) {
        self.directory = directory
    }

    /// 由账户宿主发放当前代次，不接收模型提供的账号身份。
    func bind(scope: NivoLifeScope) { activeScope = scope }

    /// 退出时先撤销导入能力，迟到的照片读取结果不能重新创建被删除的账户目录。
    func revoke() { activeScope = nil }

    /// 保存多张背景，坏索引抛错并保留原文件，不自动清空。
    func list(scope: NivoLifeScope) throws -> [NivoFocusBackground] {
        try check(scope)
        let path = folder(scope.ownerKey).appendingPathComponent("index.json")
        guard FileManager.default.fileExists(atPath: path.path) else { return [] }
        let items = try JSONDecoder().decode([NivoFocusBackground].self, from: Data(contentsOf: path))
        guard items.count <= maximumCount, items.allSatisfy({ UUID(uuidString: $0.id) != nil }),
              Set(items.map(\.id)).count == items.count else { throw NivoLifeError.corruptStore }
        return items.sorted { $0.createdAt > $1.createdAt }
    }

    /// 后台缩小到2400像素并重新编码，避免每次展示解码整张手机照片。
    func add(_ data: Data, scope: NivoLifeScope) throws -> NivoFocusBackground {
        var items = try list(scope: scope)
        guard items.count < maximumCount else { throw NivoFocusBackgroundError.full }
        guard data.count <= 32 * 1_024 * 1_024 else { throw NivoFocusBackgroundError.tooLarge }
        let prepared = try Self.prepare(data, pixels: 2_400)
        let item = NivoFocusBackground(id: UUID().uuidString, createdAt: Date())
        try FileManager.default.createDirectory(at: folder(scope.ownerKey), withIntermediateDirectories: true)
        let target = try file(item.id, owner: scope.ownerKey)
        try prepared.write(to: target, options: .atomic)
        items.insert(item, at: 0)
        do { try save(items, scope: scope) }
        catch { try? FileManager.default.removeItem(at: target); throw error }
        return item
    }

    /// 删除前先更新索引，读图找不到文件时会退回默认矢量景观。
    func remove(_ item: NivoFocusBackground, scope: NivoLifeScope) throws {
        var items = try list(scope: scope)
        items.removeAll { $0.id == item.id }
        try save(items, scope: scope)
        NivoFocusPreferences.removeBackground(item.id, owner: scope.ownerKey)
        let path = try file(item.id, owner: scope.ownerKey)
        if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
    }

    /// 缩略图只解码小尺寸数据，滚动背景列表不会加载所有大图。
    func imageData(id: String, scope: NivoLifeScope, thumbnail: Bool) throws -> Data {
        try check(scope)
        let data = try Data(contentsOf: file(id, owner: scope.ownerKey))
        return thumbnail ? try Self.prepare(data, pixels: 480) : data
    }

    private func file(_ id: String, owner: String) throws -> URL {
        guard UUID(uuidString: id) != nil else { throw NivoLifeError.invalidField("background") }
        return folder(owner).appendingPathComponent(id + ".jpg")
    }

    private func save(_ items: [NivoFocusBackground], scope: NivoLifeScope) throws {
        try check(scope)
        try JSONEncoder().encode(items).write(to: folder(scope.ownerKey).appendingPathComponent("index.json"), options: .atomic)
    }

    private func folder(_ owner: String) -> URL {
        directory.appendingPathComponent(NivoFocusPreferences.ownerHash(owner), isDirectory: true)
            .appendingPathComponent("backgrounds", isDirectory: true)
    }

    private func check(_ scope: NivoLifeScope) throws {
        guard activeScope == scope else { throw NivoLifeError.accountChanged }
    }

    private static func prepare(_ data: Data, pixels: Int) throws -> Data {
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

/// 图片导入错误提供明确恢复方式。
enum NivoFocusBackgroundError: Error {
    case full, tooLarge, unreadable
}
