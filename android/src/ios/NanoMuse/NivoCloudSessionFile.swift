import Foundation
#if os(Windows)
import WinSDK
#elseif canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// 同步文件不完整或目标变化时保留旧文件和接收批次。
enum NivoCloudSessionFileError: Error, Equatable {
    case invalidPath
    case invalidAsset
    case destinationChanged
}

/// 会话文件先有界暂存，再以同卷改名替换，失败不会先删除用户原件。
enum NivoCloudSessionFile {
    // 接收支持设置页提供的全部大小；本机上传偏好不能截断另一设备已发送的文件。
    static let MAX_ASSET_BYTES = 64 * 1_024 * 1_024

    /// 传输已落盘的附件和明确的远端版本，日期不得以当前时间兜底。
    struct Incoming: Sendable {
        let sessionID: String
        let relativePath: String
        let asset: URL
        let expectedSize: Int?
        let updatedAt: Date
    }

    enum Result: Equatable, Sendable { case applied, keptLocal }

    private struct Version: Equatable {
        let size: Int64
        let modifiedAt: Date
        let fileNumber: UInt64?
    }

    /// 文件复制不占主线程；取消仍等待实际文件操作退出后才由宿主释放会话占位。
    static func receive(_ incoming: Incoming, root: URL) async throws -> Result {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .utility) { try apply(incoming, root: root) }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: { worker.cancel() }
    }

    /// 调用方持有会话占位；测试钩子在暂存后注入真实文件故障或并发本机修改。
    @discardableResult
    static func apply(_ incoming: Incoming, root: URL, maximumBytes: Int = MAX_ASSET_BYTES,
                      beforeCommit: (URL) throws -> Void = { _ in }) throws -> Result {
        try Task.checkCancellation()
        guard incoming.updatedAt.timeIntervalSince1970.isFinite, maximumBytes > 0 else {
            throw NivoCloudSessionFileError.invalidAsset
        }
        let components = try pathComponents(sessionID: incoming.sessionID, relativePath: incoming.relativePath)
        let source = try assetVersion(incoming, maximumBytes: maximumBytes)
        let destination = try destination(root: root, components: components)
        let initial = try version(destination)
        if let initial, initial.modifiedAt >= incoming.updatedAt { return .keptLocal }
        let staged = destination.deletingLastPathComponent().appendingPathComponent(".nivo-sync-" + UUID().uuidString)
        // 清理只针对本次唯一暂存文件，不能把原件或提交错误吞掉。
        defer { try? FileManager.default.removeItem(at: staged) }
        try stage(incoming.asset, to: staged, bytes: source.size, maximumBytes: maximumBytes)
        try FileManager.default.setAttributes([.modificationDate: incoming.updatedAt], ofItemAtPath: staged.path)
        try beforeCommit(staged)
        _ = try Self.destination(root: root, components: components)
        guard try version(destination) == initial else { throw NivoCloudSessionFileError.destinationChanged }
        guard let stagedVersion = try version(staged), stagedVersion.size == source.size else {
            throw NivoCloudSessionFileError.invalidAsset
        }
        try Task.checkCancellation()
        try replace(staged, destination: destination)
        return .applied
    }

    /// 构建和接收共用路径校验，URL编码字符仅当作实际文件名，不做二次解码。
    static func pathComponents(sessionID: String, relativePath: String) throws -> [String] {
        let names = [sessionID] + relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard names.count >= 2, names.count <= 128, relativePath.utf8.count <= 4_096,
              names.allSatisfy(isSafeComponent) else { throw NivoCloudSessionFileError.invalidPath }
        return names
    }

    /// 发送侧只读取实际普通文件，不通过入站记录构造的链接读取会话目录外的内容。
    static func existingFile(root: URL, sessionID: String, relativePath: String) throws -> URL? {
        guard root.isFileURL else { throw NivoCloudSessionFileError.invalidPath }
        let components = try pathComponents(sessionID: sessionID, relativePath: relativePath)
        let file = components.reduce(root.standardizedFileURL) { $0.appendingPathComponent($1) }
        guard equivalentPath(file, file.resolvingSymlinksInPath()) else { throw NivoCloudSessionFileError.invalidPath }
        return try version(file) == nil ? nil : file
    }

    private static func isSafeComponent(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && name.utf8.count <= 255
            && !name.contains(where: { $0 == "/" || $0 == "\\" || $0 == ":" || $0 == "\0" })
            && !name.hasSuffix(".") && !name.hasSuffix(" ")
    }

    private static func destination(root: URL, components: [String]) throws -> URL {
        guard root.isFileURL else { throw NivoCloudSessionFileError.invalidPath }
        var directory = root.standardizedFileURL
        try requireDirectory(directory, allowParents: true)
        for component in components.dropLast() {
            directory.appendPathComponent(component, isDirectory: true)
            try requireDirectory(directory, allowParents: false)
        }
        return directory.appendingPathComponent(components.last!)
    }

    private static func requireDirectory(_ url: URL, allowParents: Bool) throws {
        // 宿主先规范化可信Library根；其下的符号链接、联接和非目录都不能成为写入路径。
        guard equivalentPath(url, url.resolvingSymlinksInPath()) else { throw NivoCloudSessionFileError.invalidPath }
        if let attributes = try attributes(url) {
            guard attributes[.type] as? FileAttributeType == .typeDirectory else {
                throw NivoCloudSessionFileError.invalidPath
            }
            return
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: allowParents)
        guard let created = try attributes(url), created[.type] as? FileAttributeType == .typeDirectory,
              equivalentPath(url, url.resolvingSymlinksInPath()) else { throw NivoCloudSessionFileError.invalidPath }
    }

    private static func equivalentPath(_ first: URL, _ second: URL) -> Bool {
        #if os(Windows)
        return first.standardizedFileURL.path.caseInsensitiveCompare(second.standardizedFileURL.path) == .orderedSame
        #else
        return first.standardizedFileURL.path == second.standardizedFileURL.path
        #endif
    }

    private static func assetVersion(_ incoming: Incoming, maximumBytes: Int) throws -> Version {
        guard incoming.asset.isFileURL, let actual = try version(incoming.asset),
              actual.size >= 0, actual.size <= maximumBytes,
              incoming.expectedSize.map({ $0 >= 0 && Int64($0) == actual.size }) != false else {
            throw NivoCloudSessionFileError.invalidAsset
        }
        return actual
    }

    private static func version(_ url: URL) throws -> Version? {
        guard let values = try attributes(url) else { return nil }
        guard values[.type] as? FileAttributeType == .typeRegular,
              let size = values[.size] as? NSNumber, let date = values[.modificationDate] as? Date else {
            throw NivoCloudSessionFileError.invalidAsset
        }
        return Version(size: size.int64Value, modifiedAt: date, fileNumber: (values[.systemFileNumber] as? NSNumber)?.uint64Value)
    }

    private static func attributes(_ url: URL) throws -> [FileAttributeKey: Any]? {
        do { return try FileManager.default.attributesOfItem(atPath: url.path) }
        catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile { return nil }
    }

    private static func stage(_ source: URL, to staged: URL, bytes: Int64, maximumBytes: Int) throws {
        try Data().write(to: staged, options: .withoutOverwriting)
        let reader = try FileHandle(forReadingFrom: source)
        defer { try? reader.close() }
        let writer = try FileHandle(forWritingTo: staged)
        defer { try? writer.close() }
        var copied: Int64 = 0
        while true {
            try Task.checkCancellation()
            // Apple端逐块释放Foundation对象，内存占用不随文件总大小增长。
            #if canImport(ObjectiveC)
            let hasData = try autoreleasepool {
                try copyChunk(reader, to: writer, copied: &copied, limit: min(bytes, Int64(maximumBytes)))
            }
            #else
            let hasData = try copyChunk(reader, to: writer, copied: &copied, limit: min(bytes, Int64(maximumBytes)))
            #endif
            if !hasData { break }
        }
        guard copied == bytes else { throw NivoCloudSessionFileError.invalidAsset }
        try writer.synchronize()
        try writer.close()
    }

    private static func copyChunk(_ reader: FileHandle, to writer: FileHandle,
                                  copied: inout Int64, limit: Int64) throws -> Bool {
        let chunk = try reader.read(upToCount: 64 * 1_024) ?? Data()
        if chunk.isEmpty { return false }
        copied += Int64(chunk.count)
        guard copied <= limit else { throw NivoCloudSessionFileError.invalidAsset }
        try writer.write(contentsOf: chunk)
        return true
    }

    private static func replace(_ staged: URL, destination: URL) throws {
        #if os(Windows)
        let sourcePath = Array(staged.path.utf16) + [0]
        let targetPath = Array(destination.path.utf16) + [0]
        let succeeded = sourcePath.withUnsafeBufferPointer { source in
            targetPath.withUnsafeBufferPointer { target in
                MoveFileExW(source.baseAddress, target.baseAddress, DWORD(MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH))
            }
        }
        guard succeeded else { throw NSError(domain: "NSWin32ErrorDomain", code: Int(GetLastError())) }
        #else
        guard rename(staged.path, destination.path) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        #endif
    }
}
