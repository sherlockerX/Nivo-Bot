import Foundation
#if canImport(SQLite3)
import SQLite3
#else
import CNivoSQLite
#endif

/// 将页面实际修改的字段提交到当前数据库，保留缓存尚未看到的远端记录和扩展字段。
enum NivoProviderSQLPatch {
    typealias Row = [String: NivoSQLiteWrite.Value]

    /// 表名和主键只能来自程序定义，用户数据始终通过参数绑定传入。
    enum Table: String, CaseIterable, Sendable {
        case instances = "provider_instances"
        case entries = "provider_model_entries"
        case groups = "provider_model_groups"
        case local = "provider_local_kv"
        case bindings = "provider_session_bindings"
        case inference = "provider_session_inference_configs"
        case agentLoop = "provider_agent_loop_ids"

        var keys: [String] {
            switch self {
            case .local: return ["key"]
            case .bindings, .inference: return ["session_id"]
            case .agentLoop: return ["kind", "target_id"]
            default: return ["id"]
            }
        }

        var hasTimestamp: Bool { self != .local && self != .agentLoop }
    }

    struct Snapshot: Sendable {
        let rows: [Table: [Row]]
    }

    /// 调用方持有事务；先删子表再写父表，任何冲突或故障交给同一事务回滚。
    static func apply(_ database: OpaquePointer, before: Snapshot, after: Snapshot,
                      timestamp: Double) throws {
        guard timestamp.isFinite else { throw NivoPersonalBackupError.invalidPackage }
        for table in Table.allCases.reversed() {
            try removeRows(database, table: table, before: before.rows[table] ?? [], after: after.rows[table] ?? [])
        }
        for table in Table.allCases {
            try writeRows(database, table: table, before: before.rows[table] ?? [],
                          after: after.rows[table] ?? [], timestamp: timestamp)
        }
    }

    private static func removeRows(_ database: OpaquePointer, table: Table, before: [Row], after: [Row]) throws {
        let old = try index(before, table: table)
        let new = try index(after, table: table)
        for identifier in old.keys.sorted() where new[identifier] == nil {
            guard let row = old[identifier] else { continue }
            try NivoSQLiteWrite.execute(database, sql: "DELETE FROM \(table.rawValue) WHERE \(predicate(table))",
                                        values: try keyValues(row, table: table))
        }
    }

    private static func writeRows(_ database: OpaquePointer, table: Table, before: [Row],
                                  after: [Row], timestamp: Double) throws {
        let old = try index(before, table: table)
        for row in after {
            let identifier = try identity(row, table: table)
            let baseline = old[identifier]
            guard baseline != row else { continue }
            // 更新时间属于数据库的版本信息，不能从可能陈旧的页面基线推断。
            let columns = Set(row.keys).union(table.hasTimestamp ? ["updated_at"] : []).sorted()
            try validateColumns(columns)
            let existing = try readRow(database, table: table, columns: columns, key: row)
            if let existing {
                try updateRow(database, table: table, baseline: baseline, proposed: row,
                              current: existing, timestamp: timestamp)
            } else {
                // 已存在的行被远端删除时不能用旧页面悄悄复活，保留本机编辑供重试和冲突处理。
                guard baseline == nil else { throw NivoPersonalBackupError.snapshotChanged }
                try insertRow(database, table: table, row: row, timestamp: timestamp)
            }
        }
    }

    private static func updateRow(_ database: OpaquePointer, table: Table, baseline: Row?,
                                   proposed: Row, current: Row, timestamp: Double) throws {
        var changed = proposed.filter { !table.keys.contains($0.key) && baseline?[$0.key] != $0.value }
        if table == .entries, let baseline {
            try mergeModelJSON(baseline: baseline, proposed: proposed, current: current, changed: &changed)
        }
        if table == .groups, let baseline {
            try mergeMembers(baseline: baseline, proposed: proposed, current: current, changed: &changed, timestamp: timestamp)
        }
        changed = changed.filter { current[$0.key] != $0.value }
        guard !changed.isEmpty else { return }
        if table == .entries, case .real(let proposedTime?) = changed["user_modified_at"] {
            changed["user_modified_at"] = .real(try advancingTimestamp(proposedTime, after: current["user_modified_at"]))
        }
        if table.hasTimestamp {
            changed["updated_at"] = .real(try advancingTimestamp(timestamp, after: current["updated_at"]))
        }
        let columns = changed.keys.sorted()
        try validateColumns(columns)
        let assignments = columns.map { "\($0) = ?" }.joined(separator: ", ")
        let values = columns.compactMap { changed[$0] } + (try keyValues(proposed, table: table))
        try NivoSQLiteWrite.execute(database,
            sql: "UPDATE \(table.rawValue) SET \(assignments) WHERE \(predicate(table))", values: values)
    }

    /// LWW要求后续本机编辑严格晚于已看到的版本；毫秒步长也保留Date和同步编码的精度。
    private static func advancingTimestamp(_ proposed: Double, after previous: NivoSQLiteWrite.Value?) throws -> Double {
        guard proposed.isFinite else { throw NivoPersonalBackupError.invalidPackage }
        guard case .real(let stored?) = previous else { return proposed }
        guard stored.isFinite else { throw NivoPersonalBackupError.invalidPackage }
        let result = proposed > stored ? proposed : max(stored + 0.001, stored.nextUp)
        guard result.isFinite else { throw NivoPersonalBackupError.invalidPackage }
        return result
    }

    private static func insertRow(_ database: OpaquePointer, table: Table, row: Row, timestamp: Double) throws {
        var inserted = row
        if table.hasTimestamp { inserted["updated_at"] = .real(timestamp) }
        let columns = inserted.keys.sorted()
        try validateColumns(columns)
        let placeholders = Array(repeating: "?", count: columns.count).joined(separator: ",")
        try NivoSQLiteWrite.execute(database,
            sql: "INSERT INTO \(table.rawValue) (\(columns.joined(separator: ","))) VALUES (\(placeholders))",
            values: columns.compactMap { inserted[$0] })
    }

    private static func readRow(_ database: OpaquePointer, table: Table, columns: [String], key: Row) throws -> Row? {
        try NivoSQLiteWrite.readRow(database,
            sql: "SELECT \(columns.joined(separator: ",")) FROM \(table.rawValue) WHERE \(predicate(table))",
            values: keyValues(key, table: table)) { statement in
                var row: Row = [:]
                for (offset, column) in columns.enumerated() {
                    let position = Int32(offset)
                    switch sqlite3_column_type(statement, position) {
                    case SQLITE_INTEGER: row[column] = .integer(sqlite3_column_int64(statement, position))
                    case SQLITE_FLOAT: row[column] = .real(sqlite3_column_double(statement, position))
                    case SQLITE_TEXT:
                        let length = Int(sqlite3_column_bytes(statement, position))
                        guard let bytes = sqlite3_column_text(statement, position) else {
                            throw NivoPersonalBackupError.invalidPackage
                        }
                        row[column] = .text(String(decoding: UnsafeBufferPointer(start: bytes, count: length), as: UTF8.self))
                    case SQLITE_NULL:
                        // NULL仍按候选列的类型表达，避免nil整数和nil文本产生无意义更新。
                        switch key[column] {
                        case .integer: row[column] = .integer(nil)
                        case .real: row[column] = .real(nil)
                        default: row[column] = .text(nil)
                        }
                    default: throw NivoPersonalBackupError.invalidPackage
                    }
                }
                return row
            }
    }

    private static func index(_ rows: [Row], table: Table) throws -> [String: Row] {
        var result: [String: Row] = [:]
        for row in rows {
            let key = try identity(row, table: table)
            guard result.updateValue(row, forKey: key) == nil else { throw NivoPersonalBackupError.invalidPackage }
        }
        return result
    }

    private static func identity(_ row: Row, table: Table) throws -> String {
        let parts = try table.keys.map { column -> String in
            guard case .text(let value?) = row[column] else { throw NivoPersonalBackupError.invalidPackage }
            return value
        }
        return String(decoding: try JSONEncoder().encode(parts), as: UTF8.self)
    }

    private static func keyValues(_ row: Row, table: Table) throws -> [NivoSQLiteWrite.Value] {
        _ = try identity(row, table: table)
        return table.keys.compactMap { row[$0] }
    }

    private static func predicate(_ table: Table) -> String {
        table.keys.map { "\($0) = ?" }.joined(separator: " AND ")
    }

    private static func validateColumns(_ columns: [String]) throws {
        guard !columns.isEmpty, columns.allSatisfy({ column in
            !column.isEmpty && column.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 95 }
        }) else { throw NivoPersonalBackupError.invalidPackage }
    }

    /// 同一个模型的名称修改不能覆盖另一端刚设置的上下文或推理能力，也保留未知扩展键。
    private static func mergeModelJSON(baseline: Row, proposed: Row, current: Row, changed: inout Row) throws {
        for column in ["base_model_json", "overrides_json"] where changed[column] != nil {
            let prior = try object(baseline[column])
            let next = try object(proposed[column])
            var merged = try object(current[column])
            for key in Set(prior.keys).union(next.keys) {
                let oldValue = prior[key] ?? NSNull()
                let newValue = next[key] ?? NSNull()
                if !NSDictionary(dictionary: [key: oldValue]).isEqual(to: [key: newValue]) {
                    merged[key] = next[key]
                }
            }
            if merged.isEmpty, proposed[column] == .text(nil) { changed[column] = .text(nil) }
            else {
                changed[column] = .text(String(decoding: try JSONSerialization.data(withJSONObject: merged,
                    options: [.sortedKeys, .fragmentsAllowed]), as: UTF8.self))
            }
        }
    }

    private static func object(_ value: NivoSQLiteWrite.Value?) throws -> [String: Any] {
        guard case .text(let encoded?) = value else { return [:] }
        guard let object = try JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [String: Any] else {
            throw NivoPersonalBackupError.invalidPackage
        }
        return object
    }

    /// 成员增删遵循现有时间戳协议；只重排本机真正调整的顺序，保留未见过的远端成员。
    private static func mergeMembers(baseline: Row, proposed: Row, current: Row, changed: inout Row, timestamp: Double) throws {
        let columns = ["member_entry_ids_json", "added_members_json", "removed_members_json"]
        guard columns.contains(where: { changed[$0] != nil }) else { return }
        let priorOrder = try members(baseline)
        let proposedOrder = try members(proposed)
        let currentOrder = try members(current)
        var added = try timestamps(current, column: "added_members_json")
        var removed = try timestamps(current, column: "removed_members_json")
        for member in currentOrder where added[member] == nil { added[member] = Date.distantPast.timeIntervalSince1970 }
        for (member, time) in try timestamps(proposed, column: "added_members_json") {
            added[member] = max(added[member] ?? -.infinity, time)
        }
        for (member, time) in try timestamps(proposed, column: "removed_members_json") {
            removed[member] = max(removed[member] ?? -.infinity, time)
        }
        let priorSet = Set(priorOrder)
        let proposedSet = Set(proposedOrder)
        let removedHere = priorSet.subtracting(proposedSet)
        let addedHere = proposedSet.subtracting(priorSet)
        let proposedAdded = try timestamps(proposed, column: "added_members_json")
        let proposedRemoved = try timestamps(proposed, column: "removed_members_json")
        let priorAdded = try timestamps(baseline, column: "added_members_json")
        let priorRemoved = try timestamps(baseline, column: "removed_members_json")
        // 只推进页面已见的因果版本，不借当前数据库中未见的远端事件强行覆盖并发修改。
        for member in addedHere {
            let observed = max(priorAdded[member] ?? -.infinity, priorRemoved[member] ?? -.infinity)
            let eventTime = try advancingTimestamp(proposedAdded[member] ?? timestamp,
                after: .real(observed.isFinite ? observed : nil))
            added[member] = max(added[member] ?? -.infinity, eventTime)
        }
        for member in removedHere {
            let observed = max(priorAdded[member] ?? -.infinity, priorRemoved[member] ?? -.infinity)
            let eventTime = try advancingTimestamp(proposedRemoved[member] ?? timestamp,
                after: .real(observed.isFinite ? observed : nil))
            removed[member] = max(removed[member] ?? -.infinity, eventTime)
        }
        // 只在用户调整已有成员相对顺序时采用本机顺序；新增成员不撤销远端的重排。
        let reordered = priorOrder.filter { proposedSet.contains($0) } != proposedOrder.filter { priorSet.contains($0) }
        let primary = reordered ? proposedOrder : currentOrder
        let secondary = reordered ? currentOrder : proposedOrder
        var seen = Set<String>()
        let orderCandidates = primary + secondary + added.keys.sorted()
        var order = orderCandidates.filter { seen.insert($0).inserted }
        let distantPast = Date.distantPast.timeIntervalSince1970
        order = order.filter { (added[$0] ?? distantPast) >= (removed[$0] ?? distantPast) }
        changed["member_entry_ids_json"] = .text(try json(order))
        changed["added_members_json"] = .text(try json(added))
        changed["removed_members_json"] = .text(try json(removed))
    }

    private static func members(_ row: Row) throws -> [String] {
        guard case .text(let json?) = row["member_entry_ids_json"] else { throw NivoPersonalBackupError.invalidPackage }
        return try JSONDecoder().decode([String].self, from: Data(json.utf8))
    }

    private static func timestamps(_ row: Row, column: String) throws -> [String: Double] {
        guard case .text(let json?) = row[column] else { throw NivoPersonalBackupError.invalidPackage }
        let result = try JSONDecoder().decode([String: Double].self, from: Data(json.utf8))
        guard result.values.allSatisfy(\.isFinite) else { throw NivoPersonalBackupError.invalidPackage }
        return result
    }

    private static func json<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}
