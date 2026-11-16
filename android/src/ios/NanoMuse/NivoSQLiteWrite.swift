import Foundation
#if canImport(SQLite3)
import SQLite3
#else
import CNivoSQLite
#endif

/// 严格写入保留失败阶段和SQLite返回码，不在错误中包含用户配置正文。
enum NivoSQLiteWriteError: Error, Equatable {
    case sqlite(operation: String, code: Int32)
}

/// 同步SQLite写入原语，调用者在自己的actor内使用，事务内禁止异步交接。
enum NivoSQLiteWrite {
    enum Value: Equatable, Sendable {
        case text(String?)
        case integer(Int64?)
        case real(Double?)
    }

    /// 任一步失败都撤销未提交写入；已有事务必须拒绝，不能误提交调用方的事务。
    static func transaction<T>(_ database: OpaquePointer, body: () throws -> T) throws -> T {
        guard sqlite3_get_autocommit(database) != 0 else {
            throw NivoSQLiteWriteError.sqlite(operation: "transaction_active", code: SQLITE_BUSY)
        }
        try execute(database, sql: "BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute(database, sql: "COMMIT")
            return result
        } catch {
            if sqlite3_get_autocommit(database) == 0 { try execute(database, sql: "ROLLBACK") }
            throw error
        }
    }

    /// prepare、绑定与step均须成功；空值显式绑定NULL，不能把绑定失败当作空字段写入。
    static func execute(_ database: OpaquePointer, sql: String, values: [Value] = []) throws {
        try withStatement(database, sql: sql, values: values) { statement in
            let result = sqlite3_step(statement)
            guard result == SQLITE_DONE else { throw NivoSQLiteWriteError.sqlite(operation: "step", code: result) }
        }
    }

    /// 主键查询的空结果与读取失败分别返回nil和错误，禁止因读失败绕过版本校验。
    static func readRow<T>(_ database: OpaquePointer, sql: String, values: [Value] = [],
                           decode: (OpaquePointer) throws -> T) throws -> T? {
        try withStatement(database, sql: sql, values: values) { statement in
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return nil }
            guard result == SQLITE_ROW else { throw NivoSQLiteWriteError.sqlite(operation: "read", code: result) }
            let row = try decode(statement)
            let end = sqlite3_step(statement)
            guard end == SQLITE_DONE else { throw NivoSQLiteWriteError.sqlite(operation: "read_end", code: end) }
            return row
        }
    }

    /// 完整读取结果集，末尾出现磁盘或解码错误时抛出，不能返回半份配置。
    static func readRows<T>(_ database: OpaquePointer, sql: String, values: [Value] = [],
                            decode: (OpaquePointer) throws -> T) throws -> [T] {
        try withStatement(database, sql: sql, values: values) { statement in
            var rows: [T] = []
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { return rows }
                guard result == SQLITE_ROW else { throw NivoSQLiteWriteError.sqlite(operation: "read", code: result) }
                rows.append(try decode(statement))
            }
        }
    }

    /// 迁移逐行消费只读来源，避免把全部聊天正文同时加载到内存；末尾错误仍使外层事务回滚。
    static func forEachRow(_ database: OpaquePointer, sql: String, values: [Value] = [],
                           body: (OpaquePointer) throws -> Void) throws {
        try withStatement(database, sql: sql, values: values) { statement in
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { return }
                guard result == SQLITE_ROW else { throw NivoSQLiteWriteError.sqlite(operation: "read", code: result) }
                try body(statement)
            }
        }
    }

    private static func withStatement<T>(_ database: OpaquePointer, sql: String, values: [Value],
                                          body: (OpaquePointer) throws -> T) throws -> T {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        try require(sqlite3_prepare_v2(database, sql, -1, &statement, nil), operation: "prepare")
        guard let statement else { throw NivoSQLiteWriteError.sqlite(operation: "empty_statement", code: SQLITE_MISUSE) }
        guard sqlite3_bind_parameter_count(statement) == values.count else {
            throw NivoSQLiteWriteError.sqlite(operation: "binding_count", code: SQLITE_RANGE)
        }
        for (offset, value) in values.enumerated() { try bind(value, at: Int32(offset + 1), statement: statement) }
        return try body(statement)
    }

    private static func bind(_ value: Value, at index: Int32, statement: OpaquePointer?) throws {
        let result: Int32
        switch value {
        case .text(let text?):
            guard text.utf8.count <= Int(Int32.max) else {
                throw NivoSQLiteWriteError.sqlite(operation: "bind_text", code: SQLITE_TOOBIG)
            }
            result = text.withCString {
                sqlite3_bind_text(statement, index, $0, Int32(text.utf8.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }
        case .integer(let number?): result = sqlite3_bind_int64(statement, index, number)
        case .real(let number?): result = sqlite3_bind_double(statement, index, number)
        default: result = sqlite3_bind_null(statement, index)
        }
        try require(result, operation: "bind")
    }

    private static func require(_ code: Int32, operation: String) throws {
        guard code == SQLITE_OK else { throw NivoSQLiteWriteError.sqlite(operation: operation, code: code) }
    }
}
