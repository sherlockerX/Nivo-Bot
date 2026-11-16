import Foundation

/// 远端大正文必须完整可读；附件读取失败不能悄悄变成空回复。
enum NivoCloudMessageBody {
    static let MAX_BODY_BYTES = 32 * 1_024 * 1_024

    /// 附件存在时以附件为准，读取上限也限制文件在检查后继续增长的情况。
    static func read(inline: String?, assetURL: URL?) throws -> String {
        guard let assetURL else {
            guard let inline, inline.utf8.count <= MAX_BODY_BYTES else { throw CocoaError(.fileReadCorruptFile) }
            return inline
        }
        guard assetURL.isFileURL else { throw CocoaError(.fileReadCorruptFile) }
        let attributes = try FileManager.default.attributesOfItem(atPath: assetURL.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let bytes = attributes[.size] as? NSNumber,
              (0...Int64(MAX_BODY_BYTES)).contains(bytes.int64Value) else { throw CocoaError(.fileReadCorruptFile) }
        let file = try FileHandle(forReadingFrom: assetURL)
        defer { try? file.close() }
        var data = Data()
        while data.count <= MAX_BODY_BYTES {
            let chunk = try file.read(upToCount: min(64 * 1_024, MAX_BODY_BYTES + 1 - data.count)) ?? Data()
            if chunk.isEmpty { break }
            data.append(chunk)
        }
        guard data.count <= MAX_BODY_BYTES, Int64(data.count) == bytes.int64Value,
              let body = String(data: data, encoding: .utf8) else { throw CocoaError(.fileReadCorruptFile) }
        return body
    }
}
