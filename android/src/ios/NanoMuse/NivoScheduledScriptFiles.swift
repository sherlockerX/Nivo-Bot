import Foundation
import Darwin

/// 持久脚本目录随账户资料归档，解释器的home不落在可重置的Linux镜像中。
enum NivoScheduledHome {
    static var directory: URL {
        NanoMuseDirs.root.resolvingSymlinksInPath().appendingPathComponent("routine-home", isDirectory: true)
    }

    /// 只建立真实目录，拒绝被符号链接替换的home或bin。
    static func ensure() throws -> URL {
        let home = directory
        try ensureDirectory(home)
        try ensureDirectory(home.appendingPathComponent("bin", isDirectory: true))
        return home
    }

    private static func ensureDirectory(_ url: URL) throws {
        var metadata = stat()
        if lstat(url.path, &metadata) != 0 {
            guard errno == ENOENT else { throw posixFailure() }
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            guard lstat(url.path, &metadata) == 0 else { throw posixFailure() }
        }
        guard metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              url.standardizedFileURL.path == url.resolvingSymlinksInPath().standardizedFileURL.path else {
            throw NivoLifeError.invalidField("SCRIPT_HOME_UNAVAILABLE")
        }
    }

    private static func posixFailure() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
}

/// 通过目录描述符读取文件，检查与读取始终针对同一inode，避免符号链接置换。
enum NivoScheduledScriptFiles {
    /// 返回冻结内容，后续审批与执行不再打开文件路径。
    static func read(_ script: NivoRoutineScript) throws -> NivoScheduledScriptVersion {
        try read(script: script, home: NivoScheduledHome.directory)
    }

    /// 用实际目录测试路径、特殊文件和大小边界，不替换文件系统行为。
    static func read(script: NivoRoutineScript, home: URL) throws -> NivoScheduledScriptVersion {
        try script.validate()
        let homeDescriptor = open(home.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard homeDescriptor >= 0 else { throw failure() }
        defer { close(homeDescriptor) }
        let binDescriptor = openat(homeDescriptor, "bin", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard binDescriptor >= 0 else { throw failure() }
        defer { close(binDescriptor) }
        // NONBLOCK使FIFO立即返回，后续fstat再拒绝所有非普通文件。
        let descriptor = openat(binDescriptor, script.id, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw failure() }
        defer { close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else { throw failure() }
        guard metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), metadata.st_nlink == 1,
              metadata.st_size >= 0, metadata.st_size <= NivoScheduledScriptVersion.maximumBytes else {
            throw NivoLifeError.invalidField("SCRIPT_FILE_INVALID")
        }
        return try NivoScheduledScriptVersion(script: script, data: boundedData(descriptor))
    }

    private static func boundedData(_ descriptor: Int32) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw failure() }
            if count == 0 { return data }
            guard data.count + count <= NivoScheduledScriptVersion.maximumBytes else {
                throw NivoLifeError.invalidField("SCRIPT_TOO_LARGE")
            }
            data.append(contentsOf: buffer.prefix(count))
        }
    }

    private static func failure() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
}
