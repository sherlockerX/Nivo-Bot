import Foundation
#if canImport(SQLite3)
import SQLite3
#else
import CNivoSQLite
#endif

/// SQLite在线快照错误保留操作和返回码，不能将锁冲突或损坏解释为空数据库。
enum NivoSQLiteSnapshotError: Error, Equatable {
    case sqlite(operation: String, code: Int32)
    case invalidPath
    case invalidDatabase
}

/// 通过SQLite备份接口捕获和恢复包括WAL提交在内的完整数据库，不复制活动数据库文件。
enum NivoSQLiteSnapshot {
    /// 读取源连接的已提交状态，快照必须写到本次运行中新建的路径。
    static func capture(from source: OpaquePointer, to saved: URL) throws {
        try requireDifferent(source: source, destination: saved)
        try requireNewSnapshot(saved)
        try FileManager.default.createDirectory(at: saved.deletingLastPathComponent(), withIntermediateDirectories: true)
        var didFinish = false
        defer {
            if !didFinish { try? FileManager.default.removeItem(at: saved) }
        }
        try writeSealedSnapshot(from: source, to: saved)
        try removeSealedCompanions(saved)
        didFinish = true
    }

    /// 必须确认唯一目标连接已关闭，随后才可清理Apple SQLite可能保留的共享内存文件。
    private static func writeSealedSnapshot(from source: OpaquePointer, to saved: URL) throws {
        let destination = try open(saved, flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        var isClosed = false
        defer { if !isClosed { sqlite3_close(destination) } }
        try copy(source: source, destination: destination)
        // 备份会继承源库的WAL标志；封存为单文件，后续只读校验不能再生成清单外的辅助文件。
        try seal(destination)
        try validate(destination)
        let closed = sqlite3_close(destination)
        guard closed == SQLITE_OK else { throw NivoSQLiteSnapshotError.sqlite(operation: "snapshot_close", code: closed) }
        isClosed = true
    }

    /// 打开前拒绝全部同名材料，包含悬空链接；清理阶段只能处理本次新建的快照。
    private static func requireNewSnapshot(_ saved: URL) throws {
        for suffix in ["", "-wal", "-shm"] {
            if try fileType(URL(fileURLWithPath: saved.path + suffix)) != nil {
                throw NivoSQLiteSnapshotError.invalidPath
            }
        }
    }

    /// DELETE转换、校验和关闭均成功后，残留辅助文件已不再持有独立提交，不用于旧快照或正式库。
    private static func removeSealedCompanions(_ saved: URL) throws {
        try requireSnapshotHeader(saved)
        let handle = try FileHandle(forReadingFrom: saved)
        defer { try? handle.close() }
        let header = try handle.read(upToCount: 20)
        guard let header, header.count == 20, header[18] == 1, header[19] == 1 else {
            throw NivoSQLiteSnapshotError.invalidDatabase
        }
        for suffix in ["-wal", "-shm"] {
            let companion = URL(fileURLWithPath: saved.path + suffix)
            guard let type = try fileType(companion) else { continue }
            guard type == .typeRegular else { throw NivoSQLiteSnapshotError.invalidPath }
            try FileManager.default.removeItem(at: companion)
        }
    }

    /// 仅把明确的不存在解释为缺席，权限错误和未知文件类型必须阻止后续写入。
    private static func fileType(_ file: URL) throws -> FileAttributeType? {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            guard let type = attributes[.type] as? FileAttributeType else { throw NivoSQLiteSnapshotError.invalidPath }
            return type
        } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            return nil
        }
    }

    /// 活动仓库在自己的actor内调用，恢复对现有连接原子可见，失败时保留原数据库和快照。
    static func restore(from saved: URL, into destination: OpaquePointer) throws {
        try requireDifferent(source: destination, destination: saved)
        try requireSnapshotHeader(saved)
        let source = try open(saved, flags: SQLITE_OPEN_READONLY)
        defer { sqlite3_close(source) }
        try validate(source)
        try copy(source: source, destination: destination)
    }

    /// 冷启动恢复尚未打开的仓库；先验证快照，之后才允许创建目标数据库。
    static func restore(from saved: URL, to live: URL) throws {
        guard saved.standardizedFileURL.resolvingSymlinksInPath() != live.standardizedFileURL.resolvingSymlinksInPath() else {
            throw NivoSQLiteSnapshotError.invalidPath
        }
        try requireSnapshotHeader(saved)
        let source = try open(saved, flags: SQLITE_OPEN_READONLY)
        defer { sqlite3_close(source) }
        try validate(source)
        try FileManager.default.createDirectory(at: live.deletingLastPathComponent(), withIntermediateDirectories: true)
        let destination = try open(live, flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        defer { sqlite3_close(destination) }
        try copy(source: source, destination: destination)
    }

    /// 日志准备阶段验证全部数据库快照，损坏材料不能等到覆盖其他文件后才发现。
    static func validate(_ file: URL) throws {
        try requireSnapshotHeader(file)
        let connection = try open(file, flags: SQLITE_OPEN_READONLY)
        defer { sqlite3_close(connection) }
        try validate(connection)
    }

    /// 旧快照可能仍使用WAL；仅按数据库头识别，不能因文件名像辅助文件就放宽清单。
    static func usesWAL(_ file: URL) throws -> Bool {
        try requireSnapshotHeader(file)
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        guard let header = try handle.read(upToCount: 20), header.count == 20 else {
            throw NivoSQLiteSnapshotError.invalidDatabase
        }
        return header[18] == 2 && header[19] == 2
    }

    /// SQLite会接受零字节文件作为新库；恢复材料必须有已落盘的数据库头，避免清空正式库。
    private static func requireSnapshotHeader(_ file: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.int64Value >= 512 else {
            throw NivoSQLiteSnapshotError.invalidDatabase
        }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        guard try handle.read(upToCount: 16) == Data("SQLite format 3\0".utf8) else {
            throw NivoSQLiteSnapshotError.invalidDatabase
        }
    }

    private static func open(_ url: URL, flags: Int32) throws -> OpaquePointer {
        var connection: OpaquePointer?
        let code = sqlite3_open_v2(url.path, &connection, flags | SQLITE_OPEN_FULLMUTEX, nil)
        guard code == SQLITE_OK, let connection else {
            if let connection { sqlite3_close(connection) }
            throw NivoSQLiteSnapshotError.sqlite(operation: "open", code: code)
        }
        return connection
    }

    private static func requireDifferent(source: OpaquePointer, destination: URL) throws {
        guard let path = sqlite3_db_filename(source, "main") else { throw NivoSQLiteSnapshotError.invalidPath }
        let origin = URL(fileURLWithPath: String(cString: path)).standardizedFileURL.resolvingSymlinksInPath()
        guard origin != destination.standardizedFileURL.resolvingSymlinksInPath() else { throw NivoSQLiteSnapshotError.invalidPath }
    }

    private static func copy(source: OpaquePointer, destination: OpaquePointer) throws {
        guard sqlite3_get_autocommit(source) != 0, sqlite3_get_autocommit(destination) != 0 else {
            throw NivoSQLiteSnapshotError.sqlite(operation: "transaction_active", code: SQLITE_BUSY)
        }
        guard let backup = sqlite3_backup_init(destination, "main", source, "main") else {
            throw NivoSQLiteSnapshotError.sqlite(operation: "backup_init", code: sqlite3_errcode(destination))
        }
        // 一次性复制持有SQLite读快照；遇到锁或IO错误立即结束，让上层保留恢复日志供重试。
        let step = sqlite3_backup_step(backup, -1)
        let finish = sqlite3_backup_finish(backup)
        guard step == SQLITE_DONE else { throw NivoSQLiteSnapshotError.sqlite(operation: "backup_step", code: step) }
        guard finish == SQLITE_OK else { throw NivoSQLiteSnapshotError.sqlite(operation: "backup_finish", code: finish) }
    }

    /// 只修改新建快照的日志模式，源库继续使用WAL；确认切换完成后才允许登记恢复清单。
    private static func seal(_ connection: OpaquePointer) throws {
        var statement: OpaquePointer?
        let prepared = sqlite3_prepare_v2(connection, "PRAGMA journal_mode=DELETE", -1, &statement, nil)
        defer { sqlite3_finalize(statement) }
        guard prepared == SQLITE_OK else {
            throw NivoSQLiteSnapshotError.sqlite(operation: "snapshot_seal_prepare", code: prepared)
        }
        guard sqlite3_step(statement) == SQLITE_ROW, let mode = sqlite3_column_text(statement, 0),
              String(cString: mode).lowercased() == "delete", sqlite3_step(statement) == SQLITE_DONE else {
            throw NivoSQLiteSnapshotError.sqlite(operation: "snapshot_seal", code: sqlite3_errcode(connection))
        }
    }

    private static func validate(_ connection: OpaquePointer) throws {
        var statement: OpaquePointer?
        let prepared = sqlite3_prepare_v2(connection, "PRAGMA quick_check", -1, &statement, nil)
        defer { sqlite3_finalize(statement) }
        guard prepared == SQLITE_OK else { throw NivoSQLiteSnapshotError.sqlite(operation: "quick_check_prepare", code: prepared) }
        guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0),
              String(cString: text) == "ok", sqlite3_step(statement) == SQLITE_DONE else {
            throw NivoSQLiteSnapshotError.invalidDatabase
        }
    }
}
