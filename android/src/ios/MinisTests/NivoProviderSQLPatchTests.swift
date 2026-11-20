import XCTest
#if canImport(SQLite3)
import SQLite3
#else
import CNivoSQLite
#endif
@testable import Minis

/// 在真实SQLite上验证旧页面提交与远端记录交错，不使用内存仓库替代持久化路径。
final class NivoProviderSQLPatchTests: XCTestCase {
    func testLocalFieldEditPreservesUnseenRemoteRowFieldAndTimestamp() throws {
        try withDatabase { database in
            let before = snapshot([provider("first", label: "original", enabled: true)])
            try apply(database, before: snapshot([]), after: before)
            try NivoSQLiteWrite.execute(database, sql: "UPDATE provider_instances SET is_enabled=0, extras_json='future', updated_at=7 WHERE id='first'")
            try NivoSQLiteWrite.execute(database, sql: "INSERT INTO provider_instances VALUES ('remote', 'remote', 1, 0, 8, 'keep')")
            let after = snapshot([provider("first", label: "renamed", enabled: true)])
            try apply(database, before: before, after: after)
            XCTAssertEqual(try text(database, "SELECT label FROM provider_instances WHERE id='first'"), "renamed")
            XCTAssertEqual(try text(database, "SELECT is_enabled FROM provider_instances WHERE id='first'"), "0")
            XCTAssertEqual(try text(database, "SELECT extras_json FROM provider_instances WHERE id='first'"), "future")
            XCTAssertEqual(try text(database, "SELECT updated_at FROM provider_instances WHERE id='remote'"), "8.0")
        }
    }

    func testNoOpDoesNotResurrectRemoteDeletionOrTouchOtherRows() throws {
        try withDatabase { database in
            let state = snapshot([provider("deleted", label: "old", enabled: true)])
            try apply(database, before: snapshot([]), after: state)
            try NivoSQLiteWrite.execute(database, sql: "DELETE FROM provider_instances")
            try apply(database, before: state, after: state)
            XCTAssertEqual(try text(database, "SELECT count(*) FROM provider_instances"), "0")
        }
    }

    /// 回拨设备时间后，本机连续改名仍须比已看到的远端版本新，才能通过V3的LWW比较。
    func testLocalEditsAdvancePersistedTimestampAfterClockRollback() throws {
        try withDatabase { database in
            let before = snapshot([provider("first", label: "before", enabled: true)])
            try apply(database, before: snapshot([]), after: before)
            try NivoSQLiteWrite.execute(database, sql: "UPDATE provider_instances SET updated_at=20")
            let after = snapshot([provider("first", label: "after", enabled: true)])
            try apply(database, before: before, after: after)
            let firstTimestamp = try XCTUnwrap(number(database, "SELECT updated_at FROM provider_instances"))
            XCTAssertGreaterThan(firstTimestamp, 20)

            let last = snapshot([provider("first", label: "last", enabled: true)])
            try apply(database, before: after, after: last)
            let lastTimestamp = try XCTUnwrap(number(database, "SELECT updated_at FROM provider_instances"))
            XCTAssertGreaterThan(lastTimestamp, firstTimestamp)
            try apply(database, before: last, after: last)
            XCTAssertEqual(try number(database, "SELECT updated_at FROM provider_instances"), lastTimestamp)
        }
    }

    /// 模型用户覆盖另有时间戳，回拨时也必须前进；仅刷新API元数据不能改动它。
    func testLocalModelOverrideAdvancesIntentTimestampAndMetadataRefreshPreservesIt() throws {
        try withDatabase { database in
            let before: NivoProviderSQLPatch.Row = ["id": .text("model"),
                "base_model_json": .text("{\"id\":\"model\"}"),
                "overrides_json": .text("{\"displayName\":\"before\"}"), "user_modified_at": .real(20)]
            try apply(database, before: .init(rows: [:]), after: .init(rows: [.entries: [before]]))
            var after = before
            after["overrides_json"] = .text("{\"displayName\":\"after\"}")
            after["user_modified_at"] = .real(10)
            try apply(database, before: .init(rows: [.entries: [before]]), after: .init(rows: [.entries: [after]]))
            let intentTimestamp = try XCTUnwrap(number(database, "SELECT user_modified_at FROM provider_model_entries"))
            XCTAssertGreaterThan(intentTimestamp, 20)

            var metadata = after
            metadata["base_model_json"] = .text("{\"id\":\"model\",\"future\":true}")
            try apply(database, before: .init(rows: [.entries: [after]]), after: .init(rows: [.entries: [metadata]]))
            XCTAssertEqual(try number(database, "SELECT user_modified_at FROM provider_model_entries"), intentTimestamp)
        }
    }

    func testEditOfRemotelyDeletedRowThrowsAndRollsBackOtherChanges() throws {
        try withDatabase { database in
            let before = snapshot([provider("deleted", label: "old", enabled: true)])
            let after = snapshot([provider("new", label: "new", enabled: true), provider("deleted", label: "edited", enabled: true)])
            XCTAssertThrowsError(try apply(database, before: before, after: after)) {
                XCTAssertEqual($0 as? NivoPersonalBackupError, .snapshotChanged)
            }
            XCTAssertEqual(try text(database, "SELECT count(*) FROM provider_instances"), "0")
        }
    }

    func testExplicitDeletionOnlyRemovesRowsKnownToUser() throws {
        try withDatabase { database in
            let known = provider("known", label: "known", enabled: true)
            let remote = provider("remote", label: "remote", enabled: true)
            try apply(database, before: snapshot([]), after: snapshot([known, remote]))
            try apply(database, before: snapshot([known]), after: snapshot([]))
            XCTAssertEqual(try text(database, "SELECT id FROM provider_instances"), "remote")
        }
    }

    func testUnrelatedFieldEditDoesNotTripDeleteTriggerOrEraseExtension() throws {
        try withDatabase { database in
            let before = snapshot([provider("first", label: "before", enabled: true)])
            try apply(database, before: snapshot([]), after: before)
            try NivoSQLiteWrite.execute(database, sql: "CREATE TRIGGER no_delete BEFORE DELETE ON provider_instances BEGIN SELECT RAISE(ABORT, 'no-delete'); END")
            try apply(database, before: before, after: snapshot([provider("first", label: "after", enabled: true)]))
            XCTAssertEqual(try text(database, "SELECT label FROM provider_instances"), "after")
        }
    }

    func testGroupAddPreservesRemoteAdditionAndRemoval() throws {
        try withDatabase { database in
            let before = group(members: "[\"a\"]", added: "{\"a\":1}", removed: "{}")
            let current = group(members: "[\"c\"]", added: "{\"a\":1,\"c\":3}", removed: "{\"a\":2}")
            try apply(database, before: .init(rows: [:]), after: .init(rows: [.groups: [current]]))
            let after = group(members: "[\"a\",\"b\"]", added: "{\"a\":1,\"b\":4}", removed: "{}")
            try apply(database, before: .init(rows: [.groups: [before]]), after: .init(rows: [.groups: [after]]))
            let members = try JSONDecoder().decode([String].self,
                from: Data(try XCTUnwrap(text(database, "SELECT member_entry_ids_json FROM provider_model_groups")).utf8))
            XCTAssertEqual(Set(members), ["b", "c"])
        }
    }

    func testNewerRemoteReadditionWinsOlderLocalRemoval() throws {
        try withDatabase { database in
            let before = group(members: "[\"a\"]", added: "{\"a\":1}", removed: "{}")
            let current = group(members: "[\"a\"]", added: "{\"a\":5}", removed: "{}")
            try apply(database, before: .init(rows: [:]), after: .init(rows: [.groups: [current]]))
            let after = group(members: "[]", added: "{}", removed: "{\"a\":3}")
            try apply(database, before: .init(rows: [.groups: [before]]), after: .init(rows: [.groups: [after]]))
            XCTAssertEqual(try text(database, "SELECT member_entry_ids_json FROM provider_model_groups"), "[\"a\"]")
        }
    }

    /// 用户已经见过的成员版本不能因时钟回拨阻止移除或重新加入，未见远端事件仍独立合并。
    func testMembershipChangesAdvancePastObservedHistoryAfterClockRollback() throws {
        try withDatabase { database in
            let before = group(members: "[\"a\"]", added: "{\"a\":20}", removed: "{}")
            try apply(database, before: .init(rows: [:]), after: .init(rows: [.groups: [before]]))
            let removed = group(members: "[]", added: "{}", removed: "{\"a\":10}")
            try apply(database, before: .init(rows: [.groups: [before]]), after: .init(rows: [.groups: [removed]]))
            XCTAssertEqual(try text(database, "SELECT member_entry_ids_json FROM provider_model_groups"), "[]")

            let observedRemoval = group(members: "[]", added: "{\"a\":20}", removed: "{\"a\":30}")
            try NivoSQLiteWrite.execute(database, sql: "UPDATE provider_model_groups SET removed_members_json='{\"a\":30}'")
            let readded = group(members: "[\"a\"]", added: "{\"a\":10}", removed: "{}")
            try apply(database, before: .init(rows: [.groups: [observedRemoval]]), after: .init(rows: [.groups: [readded]]))
            XCTAssertEqual(try text(database, "SELECT member_entry_ids_json FROM provider_model_groups"), "[\"a\"]")
        }
    }

    /// 两次用户操作在缓存刷新之前发生，也使用内存中刚生成的事件时间维持先后顺序。
    func testRapidRemoveAndReaddKeepsIntentWithoutWaitingForCacheRefresh() throws {
        try withDatabase { database in
            let now = Date(timeIntervalSince1970: 10)
            let previous = Date(timeIntervalSince1970: 20)
            let before = group(members: "[\"a\"]", added: "{\"a\":20}", removed: "{}")
            try apply(database, before: .init(rows: [:]), after: .init(rows: [.groups: [before]]))
            let removedTime = NivoProviderEditClock.next(after: [previous], now: now)
            let removed = group(members: "[]", added: "{}", removed: "{\"a\":\(removedTime.timeIntervalSince1970)}")
            try apply(database, before: .init(rows: [.groups: [before]]), after: .init(rows: [.groups: [removed]]))
            let addedTime = NivoProviderEditClock.next(after: [removedTime], now: now)
            let readded = group(members: "[\"a\"]", added: "{\"a\":\(addedTime.timeIntervalSince1970)}", removed: "{}")
            try apply(database, before: .init(rows: [.groups: [removed]]), after: .init(rows: [.groups: [readded]]))
            XCTAssertGreaterThan(removedTime, previous)
            XCTAssertGreaterThan(addedTime, removedTime)
            XCTAssertEqual(try text(database, "SELECT member_entry_ids_json FROM provider_model_groups"), "[\"a\"]")
        }
    }

    func testCompositeAgentSelectionAndMetadataRemainIndependent() throws {
        try withDatabase { database in
            let before = NivoProviderSQLPatch.Snapshot(rows: [.agentLoop: [
                ["kind": .text("entry"), "target_id": .text("same"), "sort_order": .integer(0)],
                ["kind": .text("group"), "target_id": .text("same"), "sort_order": .integer(0)],
            ]])
            try apply(database, before: .init(rows: [:]), after: before)
            try NivoSQLiteWrite.execute(database, sql: "INSERT INTO provider_local_kv VALUES ('legacyUuidMap', 'keep')")
            let after = NivoProviderSQLPatch.Snapshot(rows: [.agentLoop: [
                ["kind": .text("group"), "target_id": .text("same"), "sort_order": .integer(0)],
            ]])
            try apply(database, before: before, after: after)
            XCTAssertEqual(try text(database, "SELECT kind FROM provider_agent_loop_ids"), "group")
            XCTAssertEqual(try text(database, "SELECT value FROM provider_local_kv"), "keep")
        }
    }

    func testModelNameEditKeepsConcurrentContextOverrideAndUnknownMetadata() throws {
        try withDatabase { database in
            let before: NivoProviderSQLPatch.Row = ["id": .text("model"),
                "base_model_json": .text("{\"id\":\"model\"}"), "overrides_json": .text(nil)]
            var current = before
            current["base_model_json"] = .text("{\"id\":\"model\",\"future\":true}")
            current["overrides_json"] = .text("{\"contextWindow\":64000}")
            try apply(database, before: .init(rows: [:]), after: .init(rows: [.entries: [current]]))
            var after = before
            after["overrides_json"] = .text("{\"displayName\":\"mine\"}")
            try apply(database, before: .init(rows: [.entries: [before]]), after: .init(rows: [.entries: [after]]))
            let encoded = try XCTUnwrap(text(database, "SELECT overrides_json FROM provider_model_entries"))
            let values = try JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [String: Any]
            XCTAssertEqual(values?["displayName"] as? String, "mine")
            XCTAssertEqual(values?["contextWindow"] as? Int, 64000)
            XCTAssertEqual(try text(database, "SELECT base_model_json FROM provider_model_entries"),
                           "{\"id\":\"model\",\"future\":true}")
        }
    }

    /// 候选先提交、普通保存随后失败时，补偿必须撤销候选并重试当前页面的真实修改。
    func testExplicitCandidateCompensationAfterConcurrentWriteFailurePreservesCurrentIntent() throws {
        try withDatabase { database in
            let original = NivoProviderSQLPatch.Snapshot(rows: [.instances: [provider("owner", label: "original", enabled: true)],
                .entries: [model("original")]])
            let candidate = NivoProviderSQLPatch.Snapshot(rows: [.instances: original.rows[.instances]!,
                .entries: [model("original"), model("candidate")]])
            let current = NivoProviderSQLPatch.Snapshot(rows: [.instances: [provider("owner", label: "concurrent", enabled: true)],
                .entries: original.rows[.entries]!])
            try apply(database, before: .init(rows: [:]), after: original)
            try apply(database, before: original, after: candidate)
            try NivoSQLiteWrite.execute(database, sql: "CREATE TRIGGER fail_normal BEFORE UPDATE ON provider_instances BEGIN SELECT RAISE(ABORT, 'ordinary-write-failed'); END")
            XCTAssertThrowsError(try apply(database, before: original, after: current))
            try NivoSQLiteWrite.execute(database, sql: "DROP TRIGGER fail_normal")

            // 旧失败基线看不到candidate行，能重现它在补偿后残留的根因。
            try apply(database, before: original, after: current)
            XCTAssertEqual(try text(database, "SELECT count(*) FROM provider_model_entries WHERE id='candidate'"), "1")
            try apply(database, before: candidate, after: current)
            XCTAssertEqual(try text(database, "SELECT count(*) FROM provider_model_entries WHERE id='candidate'"), "0")
            XCTAssertEqual(try text(database, "SELECT id FROM provider_model_entries"), "original")
            XCTAssertEqual(try text(database, "SELECT label FROM provider_instances WHERE id='owner'"), "concurrent")
        }
    }

    /// 候选事务从未提交时，反向差异删除不存在的新增行应无操作，原记录及版本保持不变。
    func testExplicitCandidateCompensationAfterCandidateFailureLeavesOriginalRowsUntouched() throws {
        try withDatabase { database in
            let original = NivoProviderSQLPatch.Snapshot(rows: [.instances: [provider("owner", label: "original", enabled: true)],
                .entries: [model("original")]])
            let candidate = NivoProviderSQLPatch.Snapshot(rows: [.instances: [provider("owner", label: "candidate", enabled: true)],
                .entries: [model("original", displayName: "candidate"), model("candidate")]])
            try apply(database, before: .init(rows: [:]), after: original)
            let originalProviderTime = try number(database, "SELECT updated_at FROM provider_instances")
            let originalModelTime = try number(database, "SELECT updated_at FROM provider_model_entries")
            let originalModelJSON = try text(database, "SELECT overrides_json FROM provider_model_entries")
            try NivoSQLiteWrite.execute(database, sql: "CREATE TRIGGER fail_candidate BEFORE INSERT ON provider_model_entries WHEN NEW.id='candidate' BEGIN SELECT RAISE(ABORT, 'candidate-write-failed'); END")
            XCTAssertThrowsError(try apply(database, before: original, after: candidate))
            try apply(database, before: candidate, after: original)

            XCTAssertEqual(try text(database, "SELECT label FROM provider_instances"), "original")
            XCTAssertEqual(try text(database, "SELECT id FROM provider_model_entries"), "original")
            XCTAssertEqual(try text(database, "SELECT overrides_json FROM provider_model_entries"), originalModelJSON)
            XCTAssertEqual(try number(database, "SELECT updated_at FROM provider_instances"), originalProviderTime)
            XCTAssertEqual(try number(database, "SELECT updated_at FROM provider_model_entries"), originalModelTime)
        }
    }

    /// 普通并发写入已经成功时，补偿只撤销候选变化，保留它和未见过的数据库记录。
    func testExplicitCandidateCompensationPreservesSuccessfulConcurrentEditAndUnseenRow() throws {
        try withDatabase { database in
            let original = NivoProviderSQLPatch.Snapshot(rows: [.instances: [provider("owner", label: "original", enabled: true)],
                .entries: [model("original")]])
            let candidate = NivoProviderSQLPatch.Snapshot(rows: [.instances: original.rows[.instances]!,
                .entries: [model("original", displayName: "candidate"), model("candidate")]])
            let current = NivoProviderSQLPatch.Snapshot(rows: [.instances: [provider("owner", label: "concurrent", enabled: true)],
                .entries: original.rows[.entries]!])
            try apply(database, before: .init(rows: [:]), after: original)
            try apply(database, before: original, after: candidate)
            try apply(database, before: original, after: current)
            try NivoSQLiteWrite.execute(database, sql: "INSERT INTO provider_model_entries(id,base_model_json,overrides_json,updated_at) VALUES ('remote','{}','{}',30)")
            try apply(database, before: candidate, after: current)

            XCTAssertEqual(try text(database, "SELECT label FROM provider_instances"), "concurrent")
            XCTAssertEqual(try text(database, "SELECT overrides_json FROM provider_model_entries WHERE id='original'"), "{\"displayName\":\"original\"}")
            XCTAssertEqual(try text(database, "SELECT count(*) FROM provider_model_entries WHERE id='candidate'"), "0")
            XCTAssertEqual(try number(database, "SELECT updated_at FROM provider_model_entries WHERE id='remote'"), 30)
        }
    }

    private func model(_ identifier: String, displayName: String = "original") -> NivoProviderSQLPatch.Row {
        ["id": .text(identifier), "base_model_json": .text("{\"id\":\"\(identifier)\"}"),
         "overrides_json": .text("{\"displayName\":\"\(displayName)\"}")]
    }

    private func provider(_ id: String, label: String, enabled: Bool) -> NivoProviderSQLPatch.Row {
        ["id": .text(id), "label": .text(label), "is_enabled": .integer(enabled ? 1 : 0), "sort_order": .integer(0)]
    }

    private func group(members: String, added: String, removed: String) -> NivoProviderSQLPatch.Row {
        ["id": .text("group"), "name": .text("group"), "member_entry_ids_json": .text(members),
         "added_members_json": .text(added), "removed_members_json": .text(removed)]
    }

    private func snapshot(_ rows: [NivoProviderSQLPatch.Row]) -> NivoProviderSQLPatch.Snapshot {
        .init(rows: [.instances: rows])
    }

    private func apply(_ database: OpaquePointer, before: NivoProviderSQLPatch.Snapshot,
                       after: NivoProviderSQLPatch.Snapshot) throws {
        try NivoSQLiteWrite.transaction(database) {
            try NivoProviderSQLPatch.apply(database, before: before, after: after, timestamp: 10)
        }
    }

    private func text(_ database: OpaquePointer, _ sql: String) throws -> String? {
        try NivoSQLiteWrite.readRow(database, sql: sql) { statement in
            sqlite3_column_text(statement, 0).map { String(cString: $0) }
        } ?? nil
    }

    private func number(_ database: OpaquePointer, _ sql: String) throws -> Double? {
        try NivoSQLiteWrite.readRow(database, sql: sql) { sqlite3_column_double($0, 0) }
    }

    private func withDatabase(_ body: (OpaquePointer) throws -> Void) throws {
        var pointer: OpaquePointer?
        let result = sqlite3_open(":memory:", &pointer)
        guard result == SQLITE_OK, let database = pointer else { throw NivoPersonalBackupError.invalidPackage }
        defer { sqlite3_close(database) }
        for sql in [
            "CREATE TABLE provider_instances(id TEXT PRIMARY KEY, label TEXT, is_enabled INTEGER, sort_order INTEGER, updated_at REAL, extras_json TEXT)",
            "CREATE TABLE provider_model_groups(id TEXT PRIMARY KEY, name TEXT, member_entry_ids_json TEXT, added_members_json TEXT, removed_members_json TEXT, updated_at REAL)",
            "CREATE TABLE provider_model_entries(id TEXT PRIMARY KEY, base_model_json TEXT, overrides_json TEXT, user_modified_at REAL, updated_at REAL)",
            "CREATE TABLE provider_agent_loop_ids(kind TEXT, target_id TEXT, sort_order INTEGER, PRIMARY KEY(kind,target_id))",
            "CREATE TABLE provider_local_kv(key TEXT PRIMARY KEY, value TEXT)",
        ] { try NivoSQLiteWrite.execute(database, sql: sql) }
        try body(database)
    }
}
