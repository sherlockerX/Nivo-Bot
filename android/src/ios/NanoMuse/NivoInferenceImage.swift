import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 给模型用的图片副本。原图留在磁盘供预览和工具读取，这里只产出像素和字节都有上限的副本。
/// 先读像素尺寸，需要时由ImageIO按目标边长解码，不展开整张原图；结果放在缓存目录，重开会话直接读取。
enum NivoInferenceImage {
    /// 长边像素上限，与发送时的处理一致。
    static let maxLongEdge = 2000
    /// 单张图片的字节上限，与`AIChatViewModel.kPerImageMaxBytes`一致。
    static let maxBytes = 5 * 1024 * 1024

    /// 可以直接放进请求的图片。
    struct Image {
        let data: Data
        let mimeType: String
    }

    /// 依次尝试的边长和JPEG质量，取第一个不超过字节上限的。
    private static let ladder: [(edge: Int, quality: Double)] = [(2000, 0.85), (1600, 0.75), (1280, 0.70), (1024, 0.60)]

    /// 图片放不进请求时留给模型的文字。
    static func placeholder(linuxPath: String?) -> String {
        guard let linuxPath else { return "[image not loaded: it could not be reduced to fit the request]" }
        return "[image not loaded: it could not be reduced to fit the request. Original at \(linuxPath) — open it with `read_image \(linuxPath)` if you need to see it.]"
    }

    /// 读取媒体文件。文件不存在，或解不开且超过字节上限时返回空。
    static func load(from url: URL, mimeType: String) -> Image? {
        guard let size = fileSize(url) else { return nil }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else { return nil }
        if fits(longEdge: longEdge(source), bytes: size) {
            guard let data = try? Data(contentsOf: url) else { return nil }
            return Image(data: data, mimeType: sniffedType(source) ?? mimeType)
        }
        if let cached = try? Data(contentsOf: cacheURL(url)), !cached.isEmpty {
            return Image(data: cached, mimeType: "image/jpeg")
        }
        guard let data = reduce(source) else { return nil }
        writeCache(data, for: url)
        return Image(data: data, mimeType: "image/jpeg")
    }

    /// 已在内存里的图片是否超过像素或字节上限，只读文件头。
    static func exceedsLimits(_ data: Data) -> Bool {
        let source = CGImageSourceCreateWithData(data as CFData, sourceOptions)
        return !fits(longEdge: source.flatMap(longEdge), bytes: data.count)
    }

    /// 缩小已在内存里的图片；解不开时返回空。
    static func reduced(_ data: Data) -> Image? {
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        return reduce(source).map { Image(data: $0, mimeType: "image/jpeg") }
    }

    /// 刚生成的推理副本直接放进缓存，下次打开会话不必再缩一遍。
    static func remember(_ data: Data, for url: URL) {
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions),
              (CGImageSourceGetType(source) as String?) == UTType.jpeg.identifier,
              fits(longEdge: longEdge(source), bytes: data.count) else { return }
        writeCache(data, for: url)
    }

    /// 打开会话前在后台备好缓存，重建历史时不在主线程缩图。
    static func prepare(_ files: [(url: URL, mimeType: String)]) async {
        guard !files.isEmpty else { return }
        await Task.detached(priority: .userInitiated) {
            for file in files {
                // 每张图单独回收解码内存。
                autoreleasepool { _ = load(from: file.url, mimeType: file.mimeType) }
            }
        }.value
    }

    private static var sourceOptions: CFDictionary { [kCGImageSourceShouldCache: false] as CFDictionary }

    /// 解不出尺寸的只看字节，交给服务端判断。
    private static func fits(longEdge: Int?, bytes: Int) -> Bool {
        bytes <= maxBytes && (longEdge ?? 0) <= maxLongEdge
    }

    private static func longEdge(_ source: CGImageSource) -> Int? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, sourceOptions) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return max(width, height)
    }

    private static func reduce(_ source: CGImageSource) -> Data? {
        for step in ladder {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: step.edge,
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
                  let data = jpeg(image, quality: step.quality) else { return nil }
            if data.count <= maxBytes { return data }
        }
        return nil
    }

    private static func jpeg(_ image: CGImage, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// 记录的类型可能与实际内容不符，以文件内容为准。
    private static func sniffedType(_ source: CGImageSource) -> String? {
        guard let identifier = CGImageSourceGetType(source) as String? else { return nil }
        return UTType(identifier)?.preferredMIMEType
    }

    private static func fileSize(_ url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int
    }

    /// 媒体文件名是随机ID且写入后不再改动，文件名即可作为缓存键。
    private static func cacheURL(_ url: URL) -> URL {
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("nivo-inference-images", isDirectory: true)
        return directory.appendingPathComponent(url.lastPathComponent + ".jpg")
    }

    /// 缓存写不进去只是下次再缩一遍。
    private static func writeCache(_ data: Data, for url: URL) {
        let target = cacheURL(url)
        try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: target, options: .atomic)
    }
}

extension RawMessage {
    /// 这条消息带的图片，包括工具结果里的截图。
    var nmImageRefs: [MediaRef] {
        parts.compactMap { part -> MediaRef? in
            switch part {
            case .mediaRef(let ref): return ref
            case .toolResult(let result): return result.mediaRef
            default: return nil
            }
        }.filter { $0.mimeType.hasPrefix("image/") }
    }
}

extension AIChatViewModel {
    /// 组装请求时的最后核对：历史里仍超过像素或字节上限的图片换成缩小后的副本，缩不动的换成文字。
    nonisolated static func nmLimitingImages(_ messages: [AgentMessage]) -> [AgentMessage] {
        var result = messages
        for index in result.indices {
            let parts = result[index].parts
            let limited = parts.map(nmLimitingImage)
            if limited.contains(where: { $0 != nil }) {
                result[index].parts = zip(parts, limited).map { original, replacement in replacement ?? original }
            }
        }
        return result
    }

    /// 不需要改动时返回空。
    private nonisolated static func nmLimitingImage(_ part: AgentContentPart) -> AgentContentPart? {
        switch part {
        case .imageData(let data, _, let linuxPath):
            guard NivoInferenceImage.exceedsLimits(data) else { return nil }
            guard let image = NivoInferenceImage.reduced(data) else { return .text(NivoInferenceImage.placeholder(linuxPath: linuxPath)) }
            return .imageData(data: image.data, mimeType: image.mimeType, linuxPath: linuxPath)
        case .toolResult(let id, let name, let content, let isError, let data?, _, let pageURL, let linuxPath):
            guard NivoInferenceImage.exceedsLimits(data) else { return nil }
            if let image = NivoInferenceImage.reduced(data) {
                return .toolResult(id: id, name: name, content: content, isError: isError, imageData: image.data,
                                   imageMimeType: image.mimeType, pageURL: pageURL, imageLinuxPath: linuxPath)
            }
            let note = NivoInferenceImage.placeholder(linuxPath: linuxPath)
            return .toolResult(id: id, name: name, content: content.isEmpty ? note : "\(content)\n\(note)", isError: isError,
                               imageData: nil, imageMimeType: nil, pageURL: pageURL, imageLinuxPath: linuxPath)
        default:
            return nil
        }
    }
}
