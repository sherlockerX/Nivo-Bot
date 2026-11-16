import Foundation
import SQLite3

private let logger = AppLogger(category: "ProviderConfigDB")

/// SQLite-backed persistence for ProviderConfig (v3 sync architecture).
///
/// Replaces the file-level last-write-wins of `provider-config.json` with
/// per-row storage so each instance / entry / group can be synced as its
/// own CloudKit record. Deletes propagate via CKRecord `op="delete"`
/// instead of application-layer tombstones — a deleted row is gone for
/// good and cannot be resurrected by a peer's stale snapshot.
///
/// **Downgrade safety**: `provider-config.json` is kept side-by-side and
/// rewritten on every mutate so a user reverting to a v2 build sees a
/// fully-current ProviderConfig snapshot. The JSON is read-only-by-v3
/// after the initial migration; SQLite is authoritative.
///
/// **Threading**: this is an `actor`, so callers must `await` mutates.
/// `ProviderConfigStore` (the `@MainActor` ObservableObject) keeps an
/// in-memory cache that UI reads synchronously; mutates kick off
/// `Task { await db.* }` for the DB write. See S3 for the wire-up.
actor ProviderConfigDB {

    // MARK: - File locations

    /// Default DB path: same MinisChat folder as `provider-config.json`.
    static func defaultURL() -> URL {
        let library = FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask)[0]
        let base = library.appendingPathComponent("MinisChat", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("provider-config.db")
    }

    static let schemaVersion: Int32 = NivoProviderSchema.version

    private let dbURL: URL
    private var db: OpaquePointer?

    // nanoMuse: 保留旧只读接口的诊断标志；严格快照直接抛出读取错误，不再返回空选择。
    private(set) var agentLoopReadFailed = false

    // MARK: - Init / schema

    init(url: URL? = nil) throws {
        let resolvedURL = url ?? Self.defaultURL()
        self.dbURL = resolvedURL

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(resolvedURL.path, &handle, flags, nil)
        guard rc == SQLITE_OK, let handle else {
            sqlite3_close(handle)
            throw ProviderConfigDBError.openFailed(path: resolvedURL.path, code: rc)
        }
        self.db = handle

        // WAL mode: same as minis.db. Tolerates concurrent reads while we
        // upsert per-row from the sync inbound path.
        Self.exec(db: handle, "PRAGMA journal_mode = WAL")
        Self.exec(db: handle, "PRAGMA foreign_keys = ON")
        Self.exec(db: handle, "PRAGMA synchronous = NORMAL")

        try Self.runMigrations(db: handle)

        logger.info("[v3] ProviderConfigDB opened at \(resolvedURL.path)")
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    // nanoMuse: 备份恢复覆盖V3权威存储，禁止把活动WAL数据库当普通文件复制或替换。
    /// 在仓库actor内创建完整SQLite快照，返回真实数据库位置供持久日志绑定。
    func nmSnapshotForRollback(to saved: URL) throws -> URL {
        guard let db else { throw NivoSQLiteSnapshotError.invalidDatabase }
        try NivoSQLiteSnapshot.capture(from: db, to: saved)
        return dbURL
    }

    /// 对现有数据库连接执行恢复，后续读取不会继续指向已经被文件替换孤立的旧句柄。
    func nmRestoreSnapshot(from saved: URL, expectedURL: URL) throws {
        guard let db, expectedURL.standardizedFileURL == dbURL.standardizedFileURL else {
            throw NivoSQLiteSnapshotError.invalidPath
        }
        try NivoSQLiteSnapshot.restore(from: saved, into: db)
    }

    // nanoMuse: 首次建库和升级使用同一可测试事务，缺列或SQL失败不能被记录为迁移完成。
    /// 数据结构版本保持上游协议值，错误向初始化调用者传播。
    private static func runMigrations(db: OpaquePointer) throws {
        try NivoProviderSchema.migrate(db)
    }

    // MARK: - Member-timestamp map JSON codec
    // [T-icloud-provider-sync-consistency] addedMembers/removedMembers travel
    // as a JSON object {entryId: epochSeconds}. Decoding tolerates nil/empty/
    // malformed input (returns [:]) so a pre-v2 group or a corrupt blob never
    // throws inside the sync hot path.

    static func decodeMemberTimestamps(_ json: String?) -> [String: Date] {
        guard let json, !json.isEmpty, json != "{}",
              let data = json.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Double]
        else { return [:] }
        var out: [String: Date] = [:]
        for (k, v) in raw { out[k] = Date(timeIntervalSince1970: v) }
        return out
    }

    // nanoMuse: 严格快照不能将损坏的成员历史当成没有增删记录。
    private static func nmDecodeMemberTimestamps(_ json: String?) throws -> [String: Date] {
        try NivoProviderMemberHistory.decodeMap(json)
    }

    static func encodeMemberTimestamps(_ map: [String: Date]) -> String {
        guard !map.isEmpty else { return "{}" }
        var raw: [String: Double] = [:]
        for (k, v) in map { raw[k] = v.timeIntervalSince1970 }
        guard let data = try? JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys]),
              let s = String(data: data, encoding: .utf8)
        else { return "{}" }
        return s
    }

    @discardableResult
    private static func exec(db: OpaquePointer, _ sql: String) -> Int32 {
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            logger.error("[v3] sqlite_exec failed (\(rc)): \(msg) — SQL: \(sql.prefix(120))")
            sqlite3_free(err)
        }
        return rc
    }

    // MARK: - Read API (used by ProviderConfigStore cache hydration in S3)

    /// Whether the DB has been populated. False = newly created, expects
    /// migration from `provider-config.json` next (Stage S2).
    func isEmpty() -> Bool {
        // nanoMuse: 旧查询保留接口，迁移和恢复使用严格入口防止误判空库。
        (try? nmIsEmpty()) ?? true
    }

    /// 初始化不能将数据库读取失败误认为首次安装。
    func nmIsEmpty() throws -> Bool {
        guard let db else { throw NivoSQLiteSnapshotError.invalidDatabase }
        guard let count = try NivoSQLiteWrite.readRow(db,
            sql: "SELECT COUNT(*) FROM provider_instances", decode: { sqlite3_column_int64($0, 0) }) else {
            throw NivoSQLiteSnapshotError.invalidDatabase
        }
        return count == 0
    }

    /// Fetch every row in `provider_instances` ordered by `sort_order`,
    /// returning the raw SQL row dicts. The caller (ProviderConfigStore in
    /// S3) maps these into `ProviderInstance` values. Returning dicts here
    /// rather than typed structs lets the read-only API stay decoupled
    /// from the model layer for now — S3 wires the mapping.
    // nanoMuse: 旧只读查询保留返回值接口，关键快照使用下面的严格入口。
    func loadAllInstanceRows() -> [[String: Any]] {
        (try? nmLoadAllInstanceRows()) ?? []
    }

    /// 严格读取全部记录，SQL失败不能返回空集合。
    private func nmLoadAllInstanceRows() throws -> [[String: Any]] {
        guard let db else { throw NivoSQLiteSnapshotError.invalidDatabase }
        let sql = """
            SELECT id, label, provider_type, credential_type, custom_base_url,
                   append_v1_suffix, image_endpoint_mode, image_endpoint_resolved,
                   is_enabled, sort_order, secret_blob, secret_kind,
                   secret_updated_at, created_at, updated_at, extras_json,
                   custom_user_agent, azure_mode
            FROM provider_instances
            ORDER BY sort_order ASC, created_at ASC
        """
        return try NivoSQLiteWrite.readRows(db, sql: sql) { stmt in
            [
                "id": Self.text(stmt, 0),
                "label": Self.text(stmt, 1),
                "provider_type": Self.text(stmt, 2),
                "credential_type": Self.optText(stmt, 3) as Any,
                "custom_base_url": Self.optText(stmt, 4) as Any,
                "append_v1_suffix": sqlite3_column_int(stmt, 5) != 0,
                "image_endpoint_mode": Self.optText(stmt, 6) as Any,
                "image_endpoint_resolved": Self.optText(stmt, 7) as Any,
                "is_enabled": sqlite3_column_int(stmt, 8) != 0,
                "sort_order": Int(sqlite3_column_int(stmt, 9)),
                "secret_blob": Self.optText(stmt, 10) as Any,
                "secret_kind": Self.optText(stmt, 11) as Any,
                "secret_updated_at": Self.optDouble(stmt, 12) as Any,
                "created_at": sqlite3_column_double(stmt, 13),
                "updated_at": sqlite3_column_double(stmt, 14),
                "extras_json": Self.optText(stmt, 15) as Any,
                "custom_user_agent": Self.optText(stmt, 16) as Any,
                "azure_mode": sqlite3_column_int(stmt, 17) != 0,
            ]
        }
    }

    // nanoMuse: 旧只读查询保留返回值接口，关键快照使用下面的严格入口。
    func loadAllEntryRows() -> [[String: Any]] {
        (try? nmLoadAllEntryRows()) ?? []
    }

    /// 严格读取全部记录，SQL失败不能返回空集合。
    private func nmLoadAllEntryRows() throws -> [[String: Any]] {
        guard let db else { throw NivoSQLiteSnapshotError.invalidDatabase }
        let sql = """
            SELECT id, provider_instance_id, base_model_json, overrides_json,
                   is_custom, is_hidden, user_modified_at, sort_order, updated_at, extras_json
            FROM provider_model_entries
            ORDER BY provider_instance_id, sort_order ASC
        """
        return try NivoSQLiteWrite.readRows(db, sql: sql) { stmt in
            [
                "id": Self.text(stmt, 0),
                "provider_instance_id": Self.text(stmt, 1),
                "base_model_json": Self.text(stmt, 2),
                "overrides_json": Self.optText(stmt, 3) as Any,
                "is_custom": sqlite3_column_int(stmt, 4) != 0,
                "is_hidden": sqlite3_column_int(stmt, 5) != 0,
                "user_modified_at": Self.optDouble(stmt, 6) as Any,
                "sort_order": Int(sqlite3_column_int(stmt, 7)),
                "updated_at": sqlite3_column_double(stmt, 8),
                "extras_json": Self.optText(stmt, 9) as Any,
            ]
        }
    }

    // nanoMuse: 旧只读查询保留返回值接口，关键快照使用下面的严格入口。
    func loadAllGroupRows() -> [[String: Any]] {
        (try? nmLoadAllGroupRows()) ?? []
    }

    /// 严格读取全部记录，SQL失败不能返回空集合。
    private func nmLoadAllGroupRows() throws -> [[String: Any]] {
        guard let db else { throw NivoSQLiteSnapshotError.invalidDatabase }
        let sql = """
            SELECT id, name, strategy, fallback_strategy, default_thinking_level,
                   context_limit_tokens, context_limit_remembered, member_entry_ids_json,
                   sort_order, updated_at, extras_json,
                   COALESCE(removed_members_json,'{}'), COALESCE(added_members_json,'{}')
            FROM provider_model_groups
            ORDER BY sort_order ASC
        """
        return try NivoSQLiteWrite.readRows(db, sql: sql) { stmt in
            [
                "id": Self.text(stmt, 0),
                "name": Self.text(stmt, 1),
                "strategy": Self.text(stmt, 2),
                "fallback_strategy": Self.text(stmt, 3),
                "default_thinking_level": Self.optText(stmt, 4) as Any,
                "context_limit_tokens": Self.optInt(stmt, 5) as Any,
                "context_limit_remembered": Self.optInt(stmt, 6) as Any,
                "member_entry_ids_json": Self.text(stmt, 7),
                "sort_order": Int(sqlite3_column_int(stmt, 8)),
                "updated_at": sqlite3_column_double(stmt, 9),
                "extras_json": Self.optText(stmt, 10) as Any,
                "removed_members_json": Self.text(stmt, 11),
                "added_members_json": Self.text(stmt, 12),
            ]
        }
    }

    /// Returns the value previously set via `setLocalKV` for the given key,
    /// or nil if no row exists. Used for `defaultPrimaryGroupId` etc.
    // nanoMuse: 严格快照必须区分空值和查询失败。
    func localKV(_ key: String) -> String? { try? nmLocalKV(key) }

    private func nmLocalKV(_ key: String) throws -> String? {
        guard let db else { throw NivoSQLiteSnapshotError.invalidDatabase }
        return try NivoSQLiteWrite.readRow(db,
            sql: "SELECT value FROM provider_local_kv WHERE key = ?", values: [.text(key)]) {
                sqlite3_column_type($0, 0) == SQLITE_NULL ? nil : Self.text($0, 0)
            } ?? nil
    }

    // MARK: - Write API (used by migration + S3 mutate-path redirects)

    /// Bulk-replace the entire sync-domain content of the DB from a
    /// `ProviderConfig` value. Used during one-shot migration from
    /// `provider-config.json` (Stage S2) and from
    /// `ProviderConfigStore.applyMergedConfigFromSync` (Stage S3).
    ///
    /// Wraps the whole replace in a single transaction so a crash partway
    /// leaves the prior contents intact. Per-row updated_at defaults to
    /// the legacy `userModifiedAt` if present, otherwise the per-row
    /// createdAt, otherwise `now`.
    /// - Parameter preserveLocalOnlyStateIfEmpty: guard for the INBOUND-SYNC
    ///   caller only. See the agent-loop block below — the guard must NOT be on
    ///   for a user-initiated save, because clearing every agent-loop model is a
    ///   legitimate action that also funnels through here via `save()`.
    func bulkReplace(from config: ProviderConfig, preserveLocalOnlyStateIfEmpty: Bool = false) {
        // nanoMuse: 旧入口保留日志兼容，账户与恢复必须调用下面的throwing入口。
        do { try nmBulkReplace(from: config, preserveLocalOnlyStateIfEmpty: preserveLocalOnlyStateIfEmpty) }
        catch { logger.error("[Nivo] provider bulk replace failed: \(error.localizedDescription)") }
    }

    /// 完整快照写入逐步检查SQL与JSON编码，任一步失败都撤销整个事务。
    func nmBulkReplace(from config: ProviderConfig, preserveLocalOnlyStateIfEmpty: Bool = false) throws {
        guard let db else { throw NivoSQLiteWriteError.sqlite(operation: "closed", code: SQLITE_MISUSE) }
        try NivoSQLiteWrite.transaction(db) {
            try nmReplaceRows(from: config, preserveLocalOnlyStateIfEmpty: preserveLocalOnlyStateIfEmpty)
        }
    }

    // nanoMuse: 普通编辑按实际差异写入，避免旧页面快照清除尚未发布的V3入站记录。
    /// 在一个actor事务内应用本机改动并读回完整配置，JSON镜像使用提交后的真实内容。
    func nmApplyConfigurationChanges(from prior: ProviderConfig, to proposed: ProviderConfig,
                                     preserveLocalOnlyStateIfEmpty: Bool = false) throws -> ProviderConfig {
        guard let db else { throw NivoSQLiteSnapshotError.invalidDatabase }
        return try NivoSQLiteWrite.transaction(db) {
            var candidate = proposed
            if preserveLocalOnlyStateIfEmpty,
               candidate.agentLoopModelEntryIds.isEmpty, candidate.agentLoopGroupIds.isEmpty {
                candidate.agentLoopModelEntryIds = try nmLoadAgentLoopIds(kind: "entry")
                candidate.agentLoopGroupIds = try nmLoadAgentLoopIds(kind: "group")
            }
            try NivoProviderSQLPatch.apply(db, before: NivoProviderConfigurationRows.snapshot(prior),
                after: NivoProviderConfigurationRows.snapshot(candidate), timestamp: Date().timeIntervalSince1970)
            var persisted = try nmDumpProviderConfig()
            persisted.deletedInstances = proposed.deletedInstances
            persisted.deletedModelEntries = proposed.deletedModelEntries
            persisted.deletedModelGroups = proposed.deletedModelGroups
            return persisted
        }
    }

    /// 同步事务内的各表替换，思考规则由独立合并协议管理，不在此处删除。
    private func nmReplaceRows(from config: ProviderConfig, preserveLocalOnlyStateIfEmpty: Bool) throws {
        guard let db else { throw NivoSQLiteWriteError.sqlite(operation: "closed", code: SQLITE_MISUSE) }
        let now = Date().timeIntervalSince1970
        // nanoMuse: 旧ID映射不属于配置快照；全量保存必须保留已学习的跨版本引用。
        let legacyMap = try nmLocalKV("legacyUuidMap")

        for table in ["provider_model_groups", "provider_model_entries", "provider_instances",
                      "provider_local_kv", "provider_session_bindings", "provider_session_inference_configs"] {
            try NivoSQLiteWrite.execute(db, sql: "DELETE FROM \(table)")
        }
        if let legacyMap { try nmRequireRow(setLocalKVRow("legacyUuidMap", value: legacyMap)) }

        // [T-icloud-agentloop-wipe] `provider_agent_loop_ids` is LOCAL-ONLY
        // state, but it rides along in ProviderConfig and therefore gets
        // rewritten by every whole-config replace — including the one that
        // fires on each inbound V3 provider record. Wiping it whenever the
        // incoming config happens to carry an empty list is how a peer's sync
        // silently erased the user's agent-loop selection (OpenMinis#98).
        //
        // CRITICAL: this guard is gated on `preserveLocalOnlyStateIfEmpty`, i.e.
        // the inbound-sync caller ONLY. A user-initiated save() also reaches
        // bulkReplace, and "clear every agent-loop model" is a legitimate user
        // action that arrives here as an empty list — blanket-preserving would
        // silently undo it, turning this fix into a worse bug than the one it
        // repairs.
        let incomingAgentLoop = config.agentLoopModelEntryIds.count + config.agentLoopGroupIds.count
        let existingAgentLoop = preserveLocalOnlyStateIfEmpty ? try nmAgentLoopRowCount() : 0
        let preserveAgentLoop = preserveLocalOnlyStateIfEmpty && incomingAgentLoop == 0 && existingAgentLoop > 0
        if preserveAgentLoop {
            logger.warning("[v3] bulkReplace PRESERVING agent-loop ids: incoming=0 existing=\(existingAgentLoop) — refusing to wipe local-only state from an empty INBOUND config")
        } else {
            try NivoSQLiteWrite.execute(db, sql: "DELETE FROM provider_agent_loop_ids")
        }

        // Instances (with inline secret_blob — actual secret material
        // still lives in Keychain; the blob is populated by S5 when
        // the v3 sync-emit path packages it for upload. Migration
        // only seeds the metadata; secret_blob is left NULL until a
        // mutate happens or the v3 builder runs once.).
        for (idx, inst) in config.instances.enumerated() {
            try nmRequireRow(upsertInstanceRow(
                id: inst.id,
                label: inst.label,
                // Preserve the original raw type for unsupported (newer-build)
                // instances so we never overwrite it with the sentinel string.
                providerType: inst.unknownProviderTypeRaw ?? inst.providerType.rawValue,
                credentialType: inst.credentialType.rawValue,
                customBaseURL: inst.customBaseURL,
                appendV1Suffix: inst.appendV1Suffix,
                imageEndpointMode: inst.imageEndpointMode.rawValue,
                imageEndpointResolved: inst.imageEndpointResolved?.rawValue,
                isEnabled: inst.isEnabled,
                sortOrder: idx,
                secretBlob: nil,
                secretKind: nil,
                secretUpdatedAt: nil,
                createdAt: inst.createdAt.timeIntervalSince1970,
                updatedAt: now,
                extrasJson: nil,
                customUserAgent: inst.customUserAgent,
                azureMode: inst.azureMode
            ))
        }

        // Entries. baseModel + overrides go in as JSON columns so the
        // row layout doesn't need to track every LLMModel/Overrides
        // field individually (those evolve independently).
        for (idx, entry) in config.modelEntries.enumerated() {
            let baseJSON = try Self.jsonString(entry.baseModel)
            let overridesJSON: String?
            if entry.overrides.isEmpty {
                overridesJSON = nil
            } else {
                overridesJSON = try Self.jsonString(entry.overrides)
            }
            try nmRequireRow(upsertEntryRow(
                // [T-provider-entry-composite-key] DB primary key stays the
                // random uuid (NOT entry.id, which is now the composite key).
                // Keeping the uuid in the id column means old group/binding
                // references (also uuids) still match the row, downgrade is
                // safe, and compositeKey lives only in memory + as the sync
                // record key (computed). Writing entry.id here was the bug that
                // put composite keys into the DB and orphaned every uuid
                // reference.
                id: entry.uuid,
                providerInstanceId: entry.providerInstanceId,
                baseModelJson: baseJSON,
                overridesJson: overridesJSON,
                isCustom: entry.isCustom,
                isHidden: entry.isHidden,
                userModifiedAt: entry.userModifiedAt?.timeIntervalSince1970,
                sortOrder: idx,
                updatedAt: entry.userModifiedAt?.timeIntervalSince1970 ?? now,
                extrasJson: nil
            ))
        }

        // Groups. memberEntryIds → JSON array column.
        for (idx, group) in config.modelGroups.enumerated() {
            let memberJSON = try Self.jsonString(group.memberEntryIds)
            try nmRequireRow(upsertGroupRow(
                id: group.id,
                name: group.name,
                strategy: group.strategy.rawValue,
                fallbackStrategy: group.fallbackStrategy.rawValue,
                defaultThinkingLevel: group.defaultThinkingLevel?.rawValue,
                contextLimitTokens: group.contextLimitTokens,
                contextLimitRemembered: group.lastContextLimitTokens,
                memberEntryIdsJson: memberJSON,
                sortOrder: idx,
                updatedAt: now,
                extrasJson: nil,
                removedMembersJson: try Self.jsonString(group.removedMembers.mapValues { $0.timeIntervalSince1970 }),
                addedMembersJson: try Self.jsonString(group.addedMembers.mapValues { $0.timeIntervalSince1970 })
            ))
        }

        // Per-device fields — never synced.
        if let v = config.defaultPrimaryGroupId {
            try nmRequireRow(setLocalKVRow("defaultPrimaryGroupId", value: v))
        }
        if let v = config.defaultSubGroupId {
            try nmRequireRow(setLocalKVRow("defaultSubGroupId", value: v))
        }
        // Voice group selectors — per-device, like the default group ids.
        if let v = config.voiceInputGroupId {
            try nmRequireRow(setLocalKVRow("voiceInputGroupId", value: v))
        }
        if let v = config.voiceOutputGroupId {
            try nmRequireRow(setLocalKVRow("voiceOutputGroupId", value: v))
        }
        // Vision group selector — per-device, same as the voice group ids.
        if let v = config.visionGroupId {
            try nmRequireRow(setLocalKVRow("visionGroupId", value: v))
        }
        for (sid, binding) in config.sessionBindings {
            let json = try Self.jsonString(binding)
            try nmRequireRow(upsertSessionBindingRow(sessionId: sid, bindingJson: json, updatedAt: now))
        }
        for (sid, cfg) in config.sessionInferenceConfigs {
            let json = try Self.jsonString(cfg)
            try nmRequireRow(upsertSessionInferenceConfigRow(sessionId: sid, configJson: json, updatedAt: now))
        }
        // Skipped entirely when the guard above kept the existing rows —
        // re-inserting an empty list would be a no-op, but stepping over it
        // keeps the "preserve" branch obviously side-effect-free.
        if !preserveAgentLoop {
            for (idx, eid) in config.agentLoopModelEntryIds.enumerated() {
                try nmRequireRow(insertAgentLoopIdRow(kind: "entry", targetId: eid, sortOrder: idx))
            }
            for (idx, gid) in config.agentLoopGroupIds.enumerated() {
                try nmRequireRow(insertAgentLoopIdRow(kind: "group", targetId: gid, sortOrder: idx))
            }
        }

        // nanoMuse: COMMIT由外层严格事务执行，此处只准备全部行。
    }

    /// Build a `ProviderConfig` value from the current DB contents.
    /// Used by ProviderConfigStore (S3) to (a) hydrate its in-memory
    /// cache after launch and (b) re-serialize provider-config.json as
    /// the downgrade safety mirror after every mutate.
    // nanoMuse: 旧只读接口保留兼容，发布和恢复必须使用严格快照。
    func dumpProviderConfig() -> ProviderConfig { (try? nmDumpProviderConfig()) ?? .empty }

    /// 读取和解码完整权威配置，任何缺失表、半份结果或损坏记录都中止发布。
    func nmDumpProviderConfig() throws -> ProviderConfig {
        let instanceRows = try nmLoadAllInstanceRows()
        let entryRows = try nmLoadAllEntryRows()
        let groupRows = try nmLoadAllGroupRows()

        var instances: [ProviderInstance] = []
        for row in instanceRows {
            guard let id = row["id"] as? String,
                  let label = row["label"] as? String,
                  let typeRaw = row["provider_type"] as? String else {
                // nanoMuse: 必需字段缺失时拒绝整份快照，避免部分配置被再次写回数据库。
                logger.error("[v3] dumpProviderConfig: instance row missing id/label/provider_type — rejecting snapshot (id=\((row["id"] as? String)?.prefix(8) ?? "nil"))")
                throw NivoPersonalBackupError.invalidPackage
            }
            // [T-icloud-provider-sync-consistency] If the provider_type string
            // is from a NEWER build this enum can't decode, do NOT drop the
            // whole instance (that's how forward-incompatible data silently
            // vanishes and — combined with sync — propagates a delete). Keep
            // the row with a best-effort fallback type so it survives the
            // round-trip; the newer build still owns the authoritative copy.
            let parsedType = ProviderType(rawValue: typeRaw)
            let providerType: ProviderType = parsedType ?? {
                logger.error("[v3] dumpProviderConfig: instance \(id.prefix(8)) has unknown provider_type='\(typeRaw)' — marking .unsupported (raw preserved) to avoid data loss")
                return .unsupported
            }()
            // Preserve the original raw type string so a re-save round-trips it
            // unchanged instead of overwriting with the sentinel.
            let unknownTypeRaw: String? = (parsedType == nil) ? typeRaw : nil
            let credentialType: ProviderCredential = {
                if let s = row["credential_type"] as? String,
                   let c = ProviderCredential(rawValue: s) {
                    return c
                }
                return .apiKey
            }()
            let imageMode: ImageEndpointMode = {
                if let s = row["image_endpoint_mode"] as? String,
                   let m = ImageEndpointMode(rawValue: s) {
                    return m
                }
                return .auto
            }()
            let imageResolved: ImageEndpointMode? = {
                if let s = row["image_endpoint_resolved"] as? String {
                    return ImageEndpointMode(rawValue: s)
                }
                return nil
            }()
            let inst = ProviderInstance(
                id: id,
                label: label,
                providerType: providerType,
                credentialType: credentialType,
                isEnabled: (row["is_enabled"] as? Bool) ?? true,
                createdAt: Date(timeIntervalSince1970: (row["created_at"] as? Double) ?? 0),
                customBaseURL: row["custom_base_url"] as? String,
                appendV1Suffix: (row["append_v1_suffix"] as? Bool) ?? true,
                imageEndpointMode: imageMode,
                imageEndpointResolved: imageResolved,
                customUserAgent: row["custom_user_agent"] as? String,
                azureMode: (row["azure_mode"] as? Bool) ?? false,
                unknownProviderTypeRaw: unknownTypeRaw
            )
            instances.append(inst)
        }

        var entries: [ModelEntry] = []
        let decoder = JSONDecoder()
        for row in entryRows {
            guard let id = row["id"] as? String,
                  let instanceId = row["provider_instance_id"] as? String,
                  let baseJSON = row["base_model_json"] as? String,
                  let baseData = baseJSON.data(using: .utf8),
                  let baseModel = try? decoder.decode(LLMModel.self, from: baseData) else {
                // nanoMuse: 解码失败时保留全部旧缓存，不把跳过损坏模型后的半份配置返回给写入方。
                logger.error("[v3] dumpProviderConfig: entry \((row["id"] as? String)?.prefix(8) ?? "nil") has unparseable base_model_json — snapshot rejected; database preserved")
                throw NivoPersonalBackupError.invalidPackage
            }
            var overrides = ModelOverrides()
            // nanoMuse: 损坏的用户覆盖值不能被默认值替代后写回。
            if let overrideJSON = row["overrides_json"] as? String {
                overrides = try decoder.decode(ModelOverrides.self, from: Data(overrideJSON.utf8))
            }
            let userModAt: Date? = {
                if let d = row["user_modified_at"] as? Double { return Date(timeIntervalSince1970: d) }
                return nil
            }()
            let entry = ModelEntry(
                uuid: id,
                providerInstanceId: instanceId,
                model: baseModel,
                overrides: overrides,
                isCustom: (row["is_custom"] as? Bool) ?? false,
                isHidden: (row["is_hidden"] as? Bool) ?? false,
                userModifiedAt: userModAt
            )
            entries.append(entry)
        }

        var groups: [ModelGroup] = []
        for row in groupRows {
            guard let id = row["id"] as? String,
                  let name = row["name"] as? String,
                  let stratRaw = row["strategy"] as? String,
                  let strategy = RoutingStrategy(rawValue: stratRaw),
                  let fbRaw = row["fallback_strategy"] as? String,
                  let fb = FallbackStrategy(rawValue: fbRaw),
                  let memberJSON = row["member_entry_ids_json"] as? String,
                  let memberData = memberJSON.data(using: .utf8),
                  let memberIds = try? decoder.decode([String].self, from: memberData) else {
                throw NivoPersonalBackupError.invalidPackage
            }
            let thinkingLevel: ThinkingLevel? = {
                if let s = row["default_thinking_level"] as? String {
                    return ThinkingLevel.decoded(s)
                }
                return nil
            }()
            let group = ModelGroup(
                id: id,
                name: name,
                memberEntryIds: memberIds,
                strategy: strategy,
                fallbackStrategy: fb,
                defaultThinkingLevel: thinkingLevel,
                contextLimitTokens: row["context_limit_tokens"] as? Int,
                lastContextLimitTokens: row["context_limit_remembered"] as? Int,
                addedMembers: try Self.nmDecodeMemberTimestamps(row["added_members_json"] as? String),
                removedMembers: try Self.nmDecodeMemberTimestamps(row["removed_members_json"] as? String)
            )
            groups.append(group)
        }

        // Local-only fields.
        let defaultPrimary = try nmLocalKV("defaultPrimaryGroupId")
        let defaultSub = try nmLocalKV("defaultSubGroupId")
        let bindings = try nmLoadAllSessionBindings()
        let inferCfgs = try nmLoadAllSessionInferenceConfigs()
        // nanoMuse: 本机选择读取失败直接中止快照，只有成功读取的空集合才表示未选择。
        let agentLoopEntriesRead = try nmLoadAgentLoopIds(kind: "entry")
        let agentLoopGroupsRead = try nmLoadAgentLoopIds(kind: "group")
        agentLoopReadFailed = false
        let agentLoopEntries = agentLoopEntriesRead
        let agentLoopGroups = agentLoopGroupsRead
        let voiceInputGroup = try nmLocalKV("voiceInputGroupId")
        let voiceOutputGroup = try nmLocalKV("voiceOutputGroupId")
        let visionGroup = try nmLocalKV("visionGroupId")

        return ProviderConfig(
            instances: instances,
            modelEntries: entries,
            modelGroups: groups,
            defaultPrimaryGroupId: defaultPrimary,
            defaultSubGroupId: defaultSub,
            sessionBindings: bindings,
            agentLoopModelEntryIds: agentLoopEntries,
            agentLoopGroupIds: agentLoopGroups,
            voiceInputGroupId: voiceInputGroup,
            voiceOutputGroupId: voiceOutputGroup,
            visionGroupId: visionGroup,
            sessionInferenceConfigs: inferCfgs
        )
    }

    /// One-shot migration from `provider-config.json` into DB. Idempotent
    /// (gated by a UserDefaults flag — caller checks it before invoking).
    /// Called by `ProviderConfigStore` in S3 on first launch of a v3 build.
    func migrateFromLegacyJSON(at jsonURL: URL) -> Bool {
        guard let data = try? Data(contentsOf: jsonURL),
              let config = try? JSONDecoder().decode(ProviderConfig.self, from: data) else {
            logger.warning("[v3] migrateFromLegacyJSON: failed to read/decode \(jsonURL.path)")
            return false
        }
        logger.info("[v3] migrateFromLegacyJSON: ingesting \(config.instances.count) instances / \(config.modelEntries.count) entries / \(config.modelGroups.count) groups")
        // nanoMuse: 迁移标志只能在完整事务提交成功后设置。
        do { try nmBulkReplace(from: config); return true }
        catch { logger.error("[Nivo] provider migration failed: \(error.localizedDescription)"); return false }
    }

    // MARK: - Per-record API (used by V3 hydrator inbound merges in S5)

    /// Fetch a single instance row. Returns nil if id not present. Used by
    /// the V3 sync builder to package an outbound record.
    func instanceRow(id: String) -> [String: Any]? {
        return loadAllInstanceRows().first { ($0["id"] as? String) == id }
    }

    func entryRow(id: String) -> [String: Any]? {
        return loadAllEntryRows().first { ($0["id"] as? String) == id }
    }

    func groupRow(id: String) -> [String: Any]? {
        return loadAllGroupRows().first { ($0["id"] as? String) == id }
    }

    /// LWW-guarded upsert from an inbound V3 SyncedProviderInstanceV3.
    /// Returns true if applied, false if skipped (local row has newer
    /// updated_at). Used by mergeProviderInstanceV3 hydrator inbound.
    func upsertInstanceFromInbound(
        id: String, label: String, providerType: String,
        credentialType: String?, customBaseURL: String?, appendV1Suffix: Bool,
        imageEndpointMode: String?, imageEndpointResolved: String?,
        isEnabled: Bool, sortOrder: Int,
        secretBlob: String?, secretKind: String?, secretUpdatedAt: Double?,
        createdAt: Double, updatedAt: Double, extrasJson: String?,
        customUserAgent: String?,
        azureMode: Bool = false
    ) throws -> Bool {
        // nanoMuse: 读取失败与本机版本较新不能共用false，否则同步游标会吞掉失败记录。
        guard let db else { throw NivoSQLiteSnapshotError.invalidDatabase }
        let localTimestamp = try NivoSQLiteWrite.readRow(db,
            sql: "SELECT updated_at FROM provider_instances WHERE id = ?", values: [.text(id)]) {
                sqlite3_column_double($0, 0)
            }
        if let localTimestamp, localTimestamp >= updatedAt { return false }
        try nmRequireRow(upsertInstanceRow(
            id: id, label: label, providerType: providerType,
            credentialType: credentialType, customBaseURL: customBaseURL,
            appendV1Suffix: appendV1Suffix,
            imageEndpointMode: imageEndpointMode, imageEndpointResolved: imageEndpointResolved,
            isEnabled: isEnabled, sortOrder: sortOrder,
            secretBlob: secretBlob, secretKind: secretKind, secretUpdatedAt: secretUpdatedAt,
            createdAt: createdAt, updatedAt: updatedAt, extrasJson: extrasJson,
            customUserAgent: customUserAgent,
            azureMode: azureMode
        ))
        return true
    }

    func upsertEntryFromInbound(
        id: String, providerInstanceId: String,
        baseModelJson: String, overridesJson: String?,
        isCustom: Bool, isHidden: Bool, userModifiedAt: Double?,
        sortOrder: Int, updatedAt: Double, extrasJson: String?
    ) throws -> Bool {
        // nanoMuse: 数据库故障向接收屏障传播，保留后续重放机会。
        guard let db else { throw NivoSQLiteSnapshotError.invalidDatabase }
        var localTs: Double?
        var localUserModifiedAt: Double?
        var localIsHidden = false
        var localOverridesJson: String?
        _ = try NivoSQLiteWrite.readRow(db,
            sql: "SELECT updated_at, user_modified_at, is_hidden, overrides_json FROM provider_model_entries WHERE id = ?",
            values: [.text(id)]) { stmt in
                localTs = sqlite3_column_double(stmt, 0)
                if sqlite3_column_type(stmt, 1) != SQLITE_NULL {
                    localUserModifiedAt = sqlite3_column_double(stmt, 1)
                }
                localIsHidden = sqlite3_column_int(stmt, 2) != 0
                if sqlite3_column_type(stmt, 3) != SQLITE_NULL {
                    localOverridesJson = Self.text(stmt, 3)
                }
        }
        if let localTs, localTs >= updatedAt { return false }

        // [T-ios-hidden-models-restored] Overlay guard — mirror the V2 merge's
        // userModifiedAt-aware conflict resolution (CloudSyncEngine
        // mergeProviderConfig) that this V3 per-record path was missing.
        //
        // The row-level updated_at LWW above is blind to WHO made the change:
        // bulkReplace stamps updated_at = userModifiedAt ?? now, so a peer
        // device's never-touched entry re-stamps to "now" on every save and
        // perpetually looks fresher than a locally-hidden entry whose
        // updated_at is frozen at the hide time. After an app update changes
        // model metadata, the peer marks ALL its entries dirty and the inbound
        // batch stomped every local isHidden back to false — the "100+ hidden
        // models all restored" report.
        //
        // Rule: the USER-INTENT overlay (isHidden / overrides / userModifiedAt)
        // only moves forward — a remote with no userModifiedAt (never edited
        // there) or an older stamp keeps the local overlay; the remote's
        // API-truth fields (baseModelJson etc.) still apply via updated_at LWW.
        var effIsHidden = isHidden
        var effOverridesJson = overridesJson
        var effUserModifiedAt = userModifiedAt
        if let localUM = localUserModifiedAt, (userModifiedAt ?? 0) < localUM {
            effIsHidden = localIsHidden
            effOverridesJson = localOverridesJson
            effUserModifiedAt = localUM
        }

        // nanoMuse: 写入前验证缓存必需字段，不能确认一条随后使整份配置无法读取的记录。
        let model = try JSONDecoder().decode(LLMModel.self, from: Data(baseModelJson.utf8))
        guard !id.isEmpty, !providerInstanceId.isEmpty, !model.id.isEmpty,
              updatedAt.isFinite, effUserModifiedAt?.isFinite != false else {
            throw NivoPersonalBackupError.invalidPackage
        }
        if let effOverridesJson {
            _ = try JSONDecoder().decode(ModelOverrides.self, from: Data(effOverridesJson.utf8))
        }

        try nmRequireRow(upsertEntryRow(
            id: id, providerInstanceId: providerInstanceId,
            baseModelJson: baseModelJson, overridesJson: effOverridesJson,
            isCustom: isCustom, isHidden: effIsHidden,
            userModifiedAt: effUserModifiedAt,
            sortOrder: sortOrder, updatedAt: updatedAt, extrasJson: extrasJson
        ))
        return true
    }

    /// [T-icloud-provider-sync-consistency] Inbound merge for a group record.
    ///
    /// Two independent merge tracks:
    ///   • SCALAR fields (name, strategy, limits, sortOrder) — last-write-wins
    ///     by `updatedAt`. Skipped when the local row is newer.
    ///   • MEMBER set — ALWAYS merged as a per-member timestamp CRDT, even when
    ///     the scalar LWW says "local newer". This is the core fix: a member
    ///     addition/removal from a peer is never dropped just because this
    ///     device touched the group's scalar fields more recently.
    ///
    /// Member merge:
    ///   addedMerged[m]   = max over local+inbound addedMembers[m]
    ///   removedMerged[m] = max over local+inbound removedMembers[m]
    ///   m is PRESENT  iff  added[m] (default .distantPast) >= removed[m] (default .distantPast)
    ///   final order   = local order first (kept stable), then inbound-only
    ///                   present members appended — both filtered to present.
    ///
    /// Returns true if anything (scalar or members) changed and was written.
    func upsertGroupFromInbound(
        id: String, name: String, strategy: String, fallbackStrategy: String,
        defaultThinkingLevel: String?, contextLimitTokens: Int?,
        contextLimitRemembered: Int?, memberEntryIdsJson: String,
        sortOrder: Int, updatedAt: Double, extrasJson: String?,
        inboundAddedMembers: [String: Date] = [:],
        inboundRemovedMembers: [String: Date] = [:]
    ) throws -> Bool {
        // nanoMuse: 成员合并使用严格读取，不能把查询失败当作新分组。
        guard let db else { throw NivoSQLiteSnapshotError.invalidDatabase }

        // Read local row (scalar ts + member state) if present.
        var localTs: Double? = nil
        var localMemberJSON = "[]"
        var localAdded: [String: Date] = [:]
        var localRemoved: [String: Date] = [:]
        _ = try NivoSQLiteWrite.readRow(db,
            sql: "SELECT updated_at, member_entry_ids_json, added_members_json, removed_members_json FROM provider_model_groups WHERE id = ?",
            values: [.text(id)]) { stmt in
                localTs = sqlite3_column_double(stmt, 0)
                localMemberJSON = Self.text(stmt, 1)
                localAdded = try Self.nmDecodeMemberTimestamps(Self.text(stmt, 2))
                localRemoved = try Self.nmDecodeMemberTimestamps(Self.text(stmt, 3))
        }

        let scalarIsNewer = (localTs == nil) || (updatedAt > localTs!)

        // nanoMuse: 本机或远端损坏列表都保留原件，不能被一次成员合并固化为空集合。
        let inboundMembers = try JSONDecoder().decode([String].self, from: Data(memberEntryIdsJson.utf8))
        let localMembers = try JSONDecoder().decode([String].self, from: Data(localMemberJSON.utf8))
        guard !id.isEmpty, updatedAt.isFinite,
              inboundAddedMembers.values.allSatisfy({ $0.timeIntervalSince1970.isFinite }),
              inboundRemovedMembers.values.allSatisfy({ $0.timeIntervalSince1970.isFinite }) else {
            throw NivoPersonalBackupError.invalidPackage
        }

        // Backfill add timestamps for members that predate the v2 schema:
        // any member currently listed with no addedMembers entry is treated as
        // "added at distantPast" so an explicit removal (which always carries a
        // real timestamp) wins, but a bare presence on one side doesn't get
        // resurrected over a real removal on the other.
        func backfill(_ members: [String], into map: inout [String: Date]) {
            for m in members where map[m] == nil { map[m] = .distantPast }
        }
        backfill(localMembers, into: &localAdded)

        // Merge add/remove maps by max-time.
        func mergeMax(_ a: [String: Date], _ b: [String: Date]) -> [String: Date] {
            var out = a
            for (k, v) in b { if let cur = out[k] { out[k] = max(cur, v) } else { out[k] = v } }
            return out
        }
        var inboundAdded = inboundAddedMembers
        backfill(inboundMembers, into: &inboundAdded)
        let addedMerged = mergeMax(localAdded, inboundAdded)
        let removedMerged = mergeMax(localRemoved, inboundRemovedMembers)

        // Determine present members: added >= removed.
        func isPresent(_ m: String) -> Bool {
            let a = addedMerged[m] ?? .distantPast
            let r = removedMerged[m] ?? .distantPast
            return a >= r
        }
        // [T-icloud-provider-sync-consistency] Final ORDER follows the group's
        // LWW: the side with the newer group updatedAt wins the member order, so
        // a reorder on the most-recently-edited device converges on every peer
        // (fallback priority is the member order, so divergent order = divergent
        // priority — a real bug if order were just "local first"). Set MEMBERS
        // is still a union (timestamp CRDT below decides presence) so no addition
        // is lost; only the ORDERING defers to the newer side. The newer side's
        // order leads; any present member it doesn't list (a concurrent add the
        // newer side hadn't seen) is appended after, in the other side's order.
        let primaryOrder = scalarIsNewer ? inboundMembers : localMembers
        let secondaryOrder = scalarIsNewer ? localMembers : inboundMembers
        var finalMembers: [String] = []
        var seen = Set<String>()
        for m in primaryOrder where isPresent(m) && !seen.contains(m) { finalMembers.append(m); seen.insert(m) }
        for m in secondaryOrder where isPresent(m) && !seen.contains(m) { finalMembers.append(m); seen.insert(m) }
        // Defensive: any present member only in addedMerged keys (order entry
        // dropped somewhere) — appended last.
        // nanoMuse: 未列入顺序的成员按ID稳定追加，避免字典枚举使重复同步不断改变顺序。
        for m in addedMerged.keys.sorted() where isPresent(m) && !seen.contains(m) { finalMembers.append(m); seen.insert(m) }

        // Prune tombstones for members that are no longer referenced anywhere
        // (keeps the maps from growing unbounded). A removed member with no
        // chance of re-add reference can drop its add entry; keep removed
        // entries only while they still dominate.
        let referenced = Set(finalMembers)
        let finalAdded = addedMerged.filter { referenced.contains($0.key) }
        // Keep removed entries that are NOT present (active tombstones) so a
        // future inbound re-add is correctly arbitrated; drop those already
        // present (their removal lost).
        let finalRemoved = removedMerged.filter { !referenced.contains($0.key) }

        // Decide scalar values: newer side wins; if local newer, keep local
        // scalars (re-read not needed — only members changed).
        let memberChanged = finalMembers != localMembers
            || Self.encodeMemberTimestamps(finalAdded) != Self.encodeMemberTimestamps(localAdded.filter { referenced.contains($0.key) })
            || Self.encodeMemberTimestamps(finalRemoved) != Self.encodeMemberTimestamps(localRemoved.filter { !referenced.contains($0.key) })

        if !scalarIsNewer && !memberChanged {
            return false  // nothing to do
        }

        // Resolve scalar fields: if inbound scalar is newer use inbound,
        // otherwise preserve local scalars by re-reading them.
        var useName = name, useStrategy = strategy, useFallback = fallbackStrategy
        var useThinking = defaultThinkingLevel, useCtx = contextLimitTokens
        var useCtxRem = contextLimitRemembered, useSort = sortOrder
        var useUpdatedAt = updatedAt, useExtras = extrasJson
        if !scalarIsNewer {
            // Local scalars win; re-read them.
            _ = try NivoSQLiteWrite.readRow(db,
                sql: "SELECT name, strategy, fallback_strategy, default_thinking_level, context_limit_tokens, context_limit_remembered, sort_order, updated_at, extras_json FROM provider_model_groups WHERE id = ?",
                values: [.text(id)]) { s2 in
                    useName = Self.text(s2, 0)
                    useStrategy = Self.text(s2, 1)
                    useFallback = Self.text(s2, 2)
                    useThinking = Self.optText(s2, 3)
                    useCtx = Self.optInt(s2, 4)
                    useCtxRem = Self.optInt(s2, 5)
                    useSort = Int(sqlite3_column_int(s2, 6))
                    useUpdatedAt = sqlite3_column_double(s2, 7)
                    useExtras = Self.optText(s2, 8)
            }
        }

        // nanoMuse: 未识别的新策略不能写进当前严格缓存；抛出后由同步宿主保留记录，等待升级或重放。
        guard RoutingStrategy(rawValue: useStrategy) != nil, FallbackStrategy(rawValue: useFallback) != nil else {
            throw NivoPersonalBackupError.invalidPackage
        }
        let finalMemberJSON = try Self.jsonString(finalMembers)
        try nmRequireRow(upsertGroupRow(
            id: id, name: useName, strategy: useStrategy, fallbackStrategy: useFallback,
            defaultThinkingLevel: useThinking,
            contextLimitTokens: useCtx,
            contextLimitRemembered: useCtxRem,
            memberEntryIdsJson: finalMemberJSON,
            sortOrder: useSort, updatedAt: useUpdatedAt, extrasJson: useExtras,
            removedMembersJson: Self.encodeMemberTimestamps(finalRemoved),
            addedMembersJson: Self.encodeMemberTimestamps(finalAdded)
        ))
        return true
    }

    /// Delete a row by id. Used by V3 deletionApplier paths. Cascading FK
    /// on provider_model_entries.provider_instance_id removes dependent
    /// entries when an instance is deleted.
    // nanoMuse: 删除失败不得确认远端墓碑已应用。
    func deleteInstanceRow(id: String) throws {
        guard let db else { throw NivoSQLiteSnapshotError.invalidDatabase }
        try NivoSQLiteWrite.execute(db, sql: "DELETE FROM provider_instances WHERE id = ?", values: [.text(id)])
    }

    // nanoMuse: 原始ID与规范ID在同一事务内删除，避免只成功一半。
    func deleteEntryRows(ids: Set<String>) throws {
        guard let db else { throw NivoSQLiteSnapshotError.invalidDatabase }
        try NivoSQLiteWrite.transaction(db) {
            for identifier in ids.sorted() {
                try NivoSQLiteWrite.execute(db, sql: "DELETE FROM provider_model_entries WHERE id = ?", values: [.text(identifier)])
            }
        }
    }

    // nanoMuse: SQL错误交给同步宿主保留游标。
    func deleteGroupRow(id: String) throws {
        guard let db else { throw NivoSQLiteSnapshotError.invalidDatabase }
        try NivoSQLiteWrite.execute(db, sql: "DELETE FROM provider_model_groups WHERE id = ?", values: [.text(id)])
    }

    // MARK: - Per-table upsert helpers (private; used by bulkReplace + S3 mutates)

    // nanoMuse: 行写入返回真实状态，严格事务逐步检查，旧调用方保留兼容返回值。
    @discardableResult
    private func upsertInstanceRow(
        id: String, label: String, providerType: String,
        credentialType: String?, customBaseURL: String?, appendV1Suffix: Bool,
        imageEndpointMode: String?, imageEndpointResolved: String?,
        isEnabled: Bool, sortOrder: Int,
        secretBlob: String?, secretKind: String?, secretUpdatedAt: Double?,
        createdAt: Double, updatedAt: Double, extrasJson: String?,
        customUserAgent: String?,
        azureMode: Bool = false
    ) -> Int32 {
        // nanoMuse: REPLACE会先删除旧行并级联清空模型，更新必须保留提供商行的身份。
        let sql = """
            INSERT INTO provider_instances
            (id, label, provider_type, credential_type, custom_base_url,
             append_v1_suffix, image_endpoint_mode, image_endpoint_resolved,
             is_enabled, sort_order, secret_blob, secret_kind, secret_updated_at,
             created_at, updated_at, extras_json, custom_user_agent, azure_mode)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                label = excluded.label,
                provider_type = excluded.provider_type,
                credential_type = excluded.credential_type,
                custom_base_url = excluded.custom_base_url,
                append_v1_suffix = excluded.append_v1_suffix,
                image_endpoint_mode = excluded.image_endpoint_mode,
                image_endpoint_resolved = excluded.image_endpoint_resolved,
                is_enabled = excluded.is_enabled,
                sort_order = excluded.sort_order,
                secret_blob = excluded.secret_blob,
                secret_kind = excluded.secret_kind,
                secret_updated_at = excluded.secret_updated_at,
                created_at = excluded.created_at,
                updated_at = excluded.updated_at,
                extras_json = excluded.extras_json,
                custom_user_agent = excluded.custom_user_agent,
                azure_mode = excluded.azure_mode
        """
        return nmExecuteRow(sql, values: [
            .text(id), .text(label), .text(providerType), .text(credentialType), .text(customBaseURL),
            .integer(appendV1Suffix ? 1 : 0), .text(imageEndpointMode), .text(imageEndpointResolved),
            .integer(isEnabled ? 1 : 0), .integer(Int64(sortOrder)), .text(secretBlob), .text(secretKind),
            .real(secretUpdatedAt), .real(createdAt), .real(updatedAt), .text(extrasJson),
            .text(customUserAgent), .integer(azureMode ? 1 : 0)
        ])
    }

    // nanoMuse: prepare、bind和step任一失败都保留返回码。
    @discardableResult
    private func upsertEntryRow(
        id: String, providerInstanceId: String,
        baseModelJson: String, overridesJson: String?,
        isCustom: Bool, isHidden: Bool, userModifiedAt: Double?,
        sortOrder: Int, updatedAt: Double, extrasJson: String?
    ) -> Int32 {
        let sql = """
            INSERT OR REPLACE INTO provider_model_entries
            (id, provider_instance_id, base_model_json, overrides_json,
             is_custom, is_hidden, user_modified_at, sort_order, updated_at, extras_json)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
        return nmExecuteRow(sql, values: [.text(id), .text(providerInstanceId), .text(baseModelJson),
            .text(overridesJson), .integer(isCustom ? 1 : 0), .integer(isHidden ? 1 : 0),
            .real(userModifiedAt), .integer(Int64(sortOrder)), .real(updatedAt), .text(extrasJson)])
    }

    // nanoMuse: 分组与成员时间戳必须完整落盘才能提交事务。
    @discardableResult
    private func upsertGroupRow(
        id: String, name: String, strategy: String, fallbackStrategy: String,
        defaultThinkingLevel: String?, contextLimitTokens: Int?,
        contextLimitRemembered: Int?, memberEntryIdsJson: String,
        sortOrder: Int, updatedAt: Double, extrasJson: String?,
        removedMembersJson: String = "{}",
        addedMembersJson: String = "{}"
    ) -> Int32 {
        let sql = """
            INSERT OR REPLACE INTO provider_model_groups
            (id, name, strategy, fallback_strategy, default_thinking_level,
             context_limit_tokens, context_limit_remembered, member_entry_ids_json,
             sort_order, updated_at, extras_json, removed_members_json, added_members_json)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
        return nmExecuteRow(sql, values: [.text(id), .text(name), .text(strategy), .text(fallbackStrategy),
            .text(defaultThinkingLevel), .integer(contextLimitTokens.map(Int64.init)),
            .integer(contextLimitRemembered.map(Int64.init)), .text(memberEntryIdsJson),
            .integer(Int64(sortOrder)), .real(updatedAt), .text(extrasJson),
            .text(removedMembersJson), .text(addedMembersJson)])
    }

    // nanoMuse: 本机指针参与同一严格事务，不能在模型写入成功后静默丢失。
    @discardableResult
    private func setLocalKVRow(_ key: String, value: String) -> Int32 {
        nmExecuteRow("INSERT OR REPLACE INTO provider_local_kv (key, value) VALUES (?, ?)", values: [.text(key), .text(value)])
    }

    // nanoMuse: ID学习直接更新独立元数据，不从尚未刷新的页面缓存重写配置。
    /// 合并并持久化旧ID映射，返回数据库中的完整结果供内存同步使用。
    func nmLearnLegacyUuids(_ pairs: [String: String]) throws -> [String: String] {
        guard let db else { throw NivoSQLiteSnapshotError.invalidDatabase }
        guard !pairs.isEmpty else { return try nmLegacyUuidMap() }
        return try NivoSQLiteWrite.transaction(db) {
            let persisted = try nmLegacyUuidMap()
            var mapping = persisted
            for (legacy, canonical) in pairs { mapping[legacy] = canonical }
            // nanoMuse: 周期性重复入站不重写未变化的大映射，避免每条模型记录产生磁盘写入。
            if mapping != persisted {
                try nmRequireRow(setLocalKVRow("legacyUuidMap", value: try Self.jsonString(mapping)))
            }
            return mapping
        }
    }

    /// 缺少映射属于首次使用，损坏映射必须保留并报告，不能清空后覆盖。
    func nmLegacyUuidMap() throws -> [String: String] {
        guard let encoded = try nmLocalKV("legacyUuidMap") else { return [:] }
        return try JSONDecoder().decode([String: String].self, from: Data(encoded.utf8))
    }

    // nanoMuse: 会话模型绑定失败需要阻止恢复报告成功。
    @discardableResult
    private func upsertSessionBindingRow(sessionId: String, bindingJson: String, updatedAt: Double) -> Int32 {
        let sql = "INSERT OR REPLACE INTO provider_session_bindings (session_id, binding_json, updated_at) VALUES (?, ?, ?)"
        return nmExecuteRow(sql, values: [.text(sessionId), .text(bindingJson), .real(updatedAt)])
    }

    // nanoMuse: 推理设置与绑定一起返回真实写入状态。
    @discardableResult
    private func upsertSessionInferenceConfigRow(sessionId: String, configJson: String, updatedAt: Double) -> Int32 {
        let sql = "INSERT OR REPLACE INTO provider_session_inference_configs (session_id, config_json, updated_at) VALUES (?, ?, ?)"
        return nmExecuteRow(sql, values: [.text(sessionId), .text(configJson), .real(updatedAt)])
    }

    // nanoMuse: 本机智能体模型选择不能在部分写入时被判定为成功。
    @discardableResult
    private func insertAgentLoopIdRow(kind: String, targetId: String, sortOrder: Int) -> Int32 {
        let sql = "INSERT OR REPLACE INTO provider_agent_loop_ids (kind, target_id, sort_order) VALUES (?, ?, ?)"
        return nmExecuteRow(sql, values: [.text(kind), .text(targetId), .integer(Int64(sortOrder))])
    }

    /// 兼容旧行调用方的状态码接口，严格恢复使用nmRequireRow将失败向上传递。
    private func nmExecuteRow(_ sql: String, values: [NivoSQLiteWrite.Value]) -> Int32 {
        guard let db else { return SQLITE_MISUSE }
        do {
            try NivoSQLiteWrite.execute(db, sql: sql, values: values)
            return SQLITE_DONE
        } catch NivoSQLiteWriteError.sqlite(_, let code) { return code }
        catch { return SQLITE_ERROR }
    }

    private func nmRequireRow(_ code: Int32) throws {
        guard code == SQLITE_DONE else { throw NivoSQLiteWriteError.sqlite(operation: "provider_row", code: code) }
    }

    // nanoMuse: 本机绑定和推理配置解码失败时保留原配置，不能静默省略。
    private func nmLoadAllSessionBindings() throws -> [String: SessionModelBinding] {
        guard let db else { throw NivoSQLiteSnapshotError.invalidDatabase }
        let rows = try NivoSQLiteWrite.readRows(db,
            sql: "SELECT session_id, binding_json FROM provider_session_bindings") { stmt in
                (Self.text(stmt, 0), try JSONDecoder().decode(SessionModelBinding.self,
                    from: Data(Self.text(stmt, 1).utf8)))
            }
        return Dictionary(rows, uniquingKeysWith: { _, latest in latest })
    }

    // nanoMuse: 本机绑定和推理配置解码失败时保留原配置，不能静默省略。
    private func nmLoadAllSessionInferenceConfigs() throws -> [String: SessionInferenceConfig] {
        guard let db else { throw NivoSQLiteSnapshotError.invalidDatabase }
        let rows = try NivoSQLiteWrite.readRows(db,
            sql: "SELECT session_id, config_json FROM provider_session_inference_configs") { stmt in
                (Self.text(stmt, 0), try JSONDecoder().decode(SessionInferenceConfig.self,
                    from: Data(Self.text(stmt, 1).utf8)))
            }
        return Dictionary(rows, uniquingKeysWith: { _, latest in latest })
    }

    /// [T-icloud-agentloop-wipe] Row count of the local-only agent-loop table.
    /// Returns 0 when the table is missing or unreadable — callers use this
    /// only to decide whether an empty inbound list would DESTROY something, so
    /// failing to 0 is the safe direction (it just skips the preserve guard and
    /// behaves as before).
    private func agentLoopRowCount() -> Int {
        guard let db else { return 0 }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM provider_agent_loop_ids", -1, &stmt, nil) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(stmt, 0))
    }

    // nanoMuse: 读取失败不能被当成本机选择为空，从而绕过保留规则。
    private func nmAgentLoopRowCount() throws -> Int {
        guard let db else { throw NivoSQLiteWriteError.sqlite(operation: "closed", code: SQLITE_MISUSE) }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let prepared = sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM provider_agent_loop_ids", -1, &statement, nil)
        guard prepared == SQLITE_OK else { throw NivoSQLiteWriteError.sqlite(operation: "count_prepare", code: prepared) }
        let step = sqlite3_step(statement)
        guard step == SQLITE_ROW else { throw NivoSQLiteWriteError.sqlite(operation: "count_step", code: step) }
        return Int(sqlite3_column_int64(statement, 0))
    }

    // nanoMuse: 智能体选择同样严格读取，失败不能被清空后保存。
    private func nmLoadAgentLoopIds(kind: String) throws -> [String] {
        guard let db else { throw NivoSQLiteSnapshotError.invalidDatabase }
        do {
            return try NivoSQLiteWrite.readRows(db,
                sql: "SELECT target_id FROM provider_agent_loop_ids WHERE kind = ? ORDER BY sort_order ASC",
                values: [.text(kind)]) { Self.text($0, 0) }
        } catch {
            agentLoopReadFailed = true
            throw error
        }
    }

    // MARK: - Bind helpers

    private static func bindOpt(_ stmt: OpaquePointer?, _ idx: Int32, _ value: String?) {
        if let v = value {
            sqlite3_bind_text(stmt, idx, v, -1, Self.SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, idx)
        }
    }

    private static func bindOptInt(_ stmt: OpaquePointer?, _ idx: Int32, _ value: Int?) {
        if let v = value {
            sqlite3_bind_int64(stmt, idx, Int64(v))
        } else {
            sqlite3_bind_null(stmt, idx)
        }
    }

    private static func bindOptDouble(_ stmt: OpaquePointer?, _ idx: Int32, _ value: Double?) {
        if let v = value {
            sqlite3_bind_double(stmt, idx, v)
        } else {
            sqlite3_bind_null(stmt, idx)
        }
    }

    private static func jsonString<T: Encodable>(_ value: T) throws -> String {
        let data = try JSONEncoder().encode(value)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    /// Convenience: counts across the four sync-domain tables. Helpful for
    /// debug RPC + post-migration sanity checks.
    func counts() -> (instances: Int, entries: Int, groups: Int) {
        guard let db else { return (0, 0, 0) }
        func one(_ sql: String) -> Int {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK,
                  sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
            return Int(sqlite3_column_int(stmt, 0))
        }
        return (
            one("SELECT COUNT(*) FROM provider_instances"),
            one("SELECT COUNT(*) FROM provider_model_entries"),
            one("SELECT COUNT(*) FROM provider_model_groups")
        )
    }

    // MARK: - Helpers

    private static let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private static func text(_ stmt: OpaquePointer?, _ col: Int32) -> String {
        guard let cString = sqlite3_column_text(stmt, col) else { return "" }
        return String(cString: cString)
    }

    private static func optText(_ stmt: OpaquePointer?, _ col: Int32) -> String? {
        guard sqlite3_column_type(stmt, col) != SQLITE_NULL,
              let cString = sqlite3_column_text(stmt, col) else { return nil }
        let s = String(cString: cString)
        return s.isEmpty ? nil : s
    }

    private static func optInt(_ stmt: OpaquePointer?, _ col: Int32) -> Int? {
        guard sqlite3_column_type(stmt, col) != SQLITE_NULL else { return nil }
        return Int(sqlite3_column_int64(stmt, col))
    }

    private static func optDouble(_ stmt: OpaquePointer?, _ col: Int32) -> Double? {
        guard sqlite3_column_type(stmt, col) != SQLITE_NULL else { return nil }
        return sqlite3_column_double(stmt, col)
    }
}

enum ProviderConfigDBError: Error {
    case openFailed(path: String, code: Int32)
}

// MARK: - Thinking rules (Phase 2 §2)

extension ProviderConfigDB {

    // nanoMuse: 页面保留旧查询接口，恢复与缓存发布走严格读取。
    func loadThinkingRules(instanceId: String) -> [ThinkingRule] {
        (try? nmLoadThinkingRules(instanceId: instanceId)) ?? []
    }

    /// SQL读取失败必须抛出；无法解释的较新规则保留原行，只跳过执行。
    func nmLoadThinkingRules(instanceId: String) throws -> [ThinkingRule] {
        guard let db else { throw NivoSQLiteSnapshotError.invalidDatabase }
        let sql = """
            SELECT id, scope_kind, scope_pattern, wire_format_json, echo_field, echo_timing, label
            FROM provider_thinking_rules
            WHERE instance_id = ? AND is_builtin = 0
            ORDER BY sort_order ASC
        """
        let rows = try NivoSQLiteWrite.readRows(db, sql: sql, values: [.text(instanceId)], decode: Self.nmDecodeThinkingRule)
        return rows.compactMap { $0 }
    }

    // nanoMuse: 删除必须保留全部规则ID，包括本版本不能解释正文的较新规则。
    /// 一次读取删除涉及的规则和数据库已见版本，设备时间回拨不产生较旧墓碑。
    func nmProviderDeletionInventory(instanceID: String, groupIDs: [String] = []) throws -> (ruleIDs: [String], lastModified: Date) {
        guard let db else { throw NivoSQLiteSnapshotError.invalidDatabase }
        return try NivoProviderDeletionInventory.read(database: db, instanceID: instanceID, groupIDs: groupIDs)
    }

    // nanoMuse: 规则没有数据库级联约束，配置确认后由删除日志重试清理。
    /// 按父提供商清除规则，保留其他提供商的规则及其版本。
    func nmDeleteProviderRules(instanceID: String) throws {
        guard let db else { throw NivoSQLiteSnapshotError.invalidDatabase }
        try NivoSQLiteWrite.execute(db, sql: "DELETE FROM provider_thinking_rules WHERE instance_id = ?", values: [.text(instanceID)])
    }

    // nanoMuse: 在数据库actor内一次读取完整规则，避免旧页面缺少父提供商或多次await混合新旧规则。
    /// 只缓存仍有父提供商的自定义规则；缺表与中途读取失败必须抛出。
    func nmThinkingRuleCacheSnapshot() throws -> [String: [ThinkingRule]] {
        guard let db else { throw NivoSQLiteSnapshotError.invalidDatabase }
        let sql = """
            SELECT r.id, r.scope_kind, r.scope_pattern, r.wire_format_json,
                   r.echo_field, r.echo_timing, r.label, r.instance_id
            FROM provider_thinking_rules r
            JOIN provider_instances p ON p.id = r.instance_id
            WHERE r.is_builtin = 0 ORDER BY r.instance_id, r.sort_order, r.id
        """
        let rows = try NivoSQLiteWrite.readRows(db, sql: sql) { statement in
            (Self.text(statement, 7), Self.nmDecodeThinkingRule(statement))
        }
        var snapshot: [String: [ThinkingRule]] = [:]
        for (instanceID, rule) in rows {
            if let rule { snapshot[instanceID, default: []].append(rule) }
        }
        return snapshot
    }

    private static func nmDecodeThinkingRule(_ statement: OpaquePointer) -> ThinkingRule? {
        let id = text(statement, 0)
        let scope = ThinkingRule.Scope.fromPersisted(kind: text(statement, 1), pattern: optText(statement, 2))
        let json = text(statement, 3)
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let format = ThinkingWireFormat.fromPersistedJSON(object) else {
            // 新版本规则保留原行，只跳过执行，日志不能泄漏用户规则正文。
            logger.warning("[ThinkingRules] skipping unsupported rule id=\(id)")
            return nil
        }
        let echo = ReasoningEchoPolicy.fromPersisted(field: optText(statement, 4), timing: optText(statement, 5))
        return ThinkingRule(kind: .custom, scope: scope, wireFormat: format,
                            reasoningEcho: echo, label: text(statement, 6), id: id)
    }

    /// Insert or update one rule. `sortOrder` is the caller's position in the list.
    @discardableResult
    func upsertThinkingRule(_ rule: ThinkingRule, instanceId: String, sortOrder: Int) -> Bool {
        guard let db else { return false }
        let payload = rule.wireFormat?.persistedJSON ?? ThinkingWireFormat.omitEverything.persistedJSON
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return false }

        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = """
            INSERT INTO provider_thinking_rules
                (id, instance_id, sort_order, scope_kind, scope_pattern, wire_format_json,
                 echo_field, echo_timing, label, is_builtin, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 0,
                    COALESCE((SELECT created_at FROM provider_thinking_rules WHERE id = ?), ?), ?)
            ON CONFLICT(id) DO UPDATE SET
                instance_id = excluded.instance_id,
                sort_order = excluded.sort_order,
                scope_kind = excluded.scope_kind,
                scope_pattern = excluded.scope_pattern,
                wire_format_json = excluded.wire_format_json,
                echo_field = excluded.echo_field,
                echo_timing = excluded.echo_timing,
                label = excluded.label,
                updated_at = excluded.updated_at
        """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            logger.error("[ThinkingRules] upsert FAILED (prepare) id=\(rule.id)")
            return false
        }
        let now = Date().timeIntervalSince1970
        sqlite3_bind_text(stmt, 1, rule.id, -1, Self.SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, instanceId, -1, Self.SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 3, Int32(sortOrder))
        sqlite3_bind_text(stmt, 4, rule.scope.persistedKind, -1, Self.SQLITE_TRANSIENT)
        if let p = rule.scope.persistedPattern {
            sqlite3_bind_text(stmt, 5, p, -1, Self.SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 5)
        }
        sqlite3_bind_text(stmt, 6, json, -1, Self.SQLITE_TRANSIENT)
        if let e = rule.reasoningEcho {
            sqlite3_bind_text(stmt, 7, e.fieldName, -1, Self.SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 8, e.persistedTiming, -1, Self.SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 7)
            sqlite3_bind_null(stmt, 8)
        }
        sqlite3_bind_text(stmt, 9, rule.label, -1, Self.SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 10, rule.id, -1, Self.SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 11, now)
        sqlite3_bind_double(stmt, 12, now)
        let ok = sqlite3_step(stmt) == SQLITE_DONE
        if !ok { logger.error("[ThinkingRules] upsert FAILED (step) id=\(rule.id)") }
        return ok
    }

    @discardableResult
    func deleteThinkingRule(id: String) -> Bool {
        // nanoMuse: 页面保留Bool接口，云同步通过严格入口取得实际错误。
        do { try nmDeleteThinkingRule(id: id); return true }
        catch { return false }
    }

    /// 删除思考规则，失败交给同步游标或恢复事务处理。
    func nmDeleteThinkingRule(id: String) throws {
        guard let db else { throw NivoSQLiteSnapshotError.invalidDatabase }
        try NivoSQLiteWrite.execute(db, sql: "DELETE FROM provider_thinking_rules WHERE id = ?", values: [.text(id)])
    }

    // MARK: - V3 sync support (T-icloud-thinking-rules-sync)

    /// The owning instance of a rule, needed by the delete path: `markDirty` is
    /// keyed by rule id alone, but the caller must know which instance's cache to
    /// refresh. Read BEFORE deleting the row.
    func thinkingRuleInstanceId(id: String) -> String? {
        guard let db else { return nil }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT instance_id FROM provider_thinking_rules WHERE id = ?", -1, &stmt, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_text(stmt, 1, id, -1, Self.SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return Self.text(stmt, 0)
    }

    /// One rule as a raw column dictionary, for the sync builder.
    ///
    /// Returns `wire_format_json` as the STORED STRING rather than a decoded
    /// `ThinkingWireFormat`. That is deliberate and is what makes the wire format
    /// forward-compatible: a rule written by a newer build using a `kind` this build
    /// has never heard of is copied through byte-for-byte instead of being dropped or
    /// coerced. Decoding happens only where the rule is USED (`loadThinkingRules`),
    /// which already skips unreadable rows one at a time.
    func thinkingRuleRow(id: String) -> [String: Any]? {
        guard let db else { return nil }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = """
            SELECT id, instance_id, sort_order, scope_kind, scope_pattern, wire_format_json,
                   echo_field, echo_timing, label, created_at, updated_at
            FROM provider_thinking_rules
            WHERE id = ? AND is_builtin = 0
        """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_text(stmt, 1, id, -1, Self.SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        var row: [String: Any] = [
            "id": Self.text(stmt, 0),
            "instance_id": Self.text(stmt, 1),
            "sort_order": Int(sqlite3_column_int(stmt, 2)),
            "scope_kind": Self.text(stmt, 3),
            "wire_format_json": Self.text(stmt, 5),
            "label": Self.text(stmt, 8),
            "created_at": sqlite3_column_double(stmt, 9),
            "updated_at": sqlite3_column_double(stmt, 10),
        ]
        if sqlite3_column_type(stmt, 4) != SQLITE_NULL { row["scope_pattern"] = Self.text(stmt, 4) }
        if sqlite3_column_type(stmt, 6) != SQLITE_NULL { row["echo_field"] = Self.text(stmt, 6) }
        if sqlite3_column_type(stmt, 7) != SQLITE_NULL { row["echo_timing"] = Self.text(stmt, 7) }
        return row
    }

    /// LWW-guarded upsert from an inbound synced record, mirroring
    /// `upsertInstanceFromInbound`: skip when the local row is newer or equal.
    ///
    /// Takes `wireFormatJson` as an opaque string for the forward-compatibility
    /// reason described on `thinkingRuleRow`. `is_builtin` is hardcoded to 0 — built-in
    /// rules are code constants that each device computes for itself and must never
    /// arrive over the wire, so an inbound record can only ever create a custom rule.
    @discardableResult
    func upsertThinkingRuleFromInbound(
        id: String, instanceId: String, sortOrder: Int,
        scopeKind: String, scopePattern: String?, wireFormatJson: String,
        echoField: String?, echoTiming: String?, label: String,
        createdAt: Double, updatedAt: Double
    ) throws -> Bool {
        // nanoMuse: 入站与恢复都区分版本跳过和SQL失败，不能提前确认游标。
        guard let db else { throw NivoSQLiteSnapshotError.invalidDatabase }
        let hasOwner = try NivoSQLiteWrite.readRow(db,
            sql: "SELECT 1 FROM provider_instances WHERE id = ?", values: [.text(instanceId)]) { _ in true }
        guard hasOwner == true else {
            throw NivoSQLiteWriteError.sqlite(operation: "thinking_rule_owner", code: SQLITE_CONSTRAINT)
        }
        return try nmUpsertThinkingRule(id: id, instanceId: instanceId, sortOrder: sortOrder,
            scopeKind: scopeKind, scopePattern: scopePattern, wireFormatJson: wireFormatJson,
            echoField: echoField, echoTiming: echoTiming, label: label, createdAt: createdAt, updatedAt: updatedAt)
    }

    /// 同一SQL语句完成时间戳比较和写入；false仅表示本机版本较新，磁盘错误抛出。
    func nmUpsertThinkingRule(
        id: String, instanceId: String, sortOrder: Int,
        scopeKind: String, scopePattern: String?, wireFormatJson: String,
        echoField: String?, echoTiming: String?, label: String,
        createdAt: Double, updatedAt: Double
    ) throws -> Bool {
        guard let db else { throw NivoSQLiteWriteError.sqlite(operation: "closed", code: SQLITE_MISUSE) }
        let sql = """
            INSERT INTO provider_thinking_rules
                (id, instance_id, sort_order, scope_kind, scope_pattern, wire_format_json,
                 echo_field, echo_timing, label, is_builtin, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                instance_id = excluded.instance_id,
                sort_order = excluded.sort_order,
                scope_kind = excluded.scope_kind,
                scope_pattern = excluded.scope_pattern,
                wire_format_json = excluded.wire_format_json,
                echo_field = excluded.echo_field,
                echo_timing = excluded.echo_timing,
                label = excluded.label,
                updated_at = excluded.updated_at
            WHERE excluded.updated_at > provider_thinking_rules.updated_at
        """
        try NivoSQLiteWrite.execute(db, sql: sql, values: [.text(id), .text(instanceId), .integer(Int64(sortOrder)),
            .text(scopeKind), .text(scopePattern), .text(wireFormatJson), .text(echoField), .text(echoTiming),
            .text(label), .real(createdAt), .real(updatedAt)])
        return sqlite3_changes(db) > 0
    }

    /// Every custom rule id across all instances — used to enumerate what needs
    /// backfilling onto the sync queue for users who authored rules before sync existed.
    func allCustomThinkingRuleIds() -> [String] {
        guard let db else { return [] }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT id FROM provider_thinking_rules WHERE is_builtin = 0", -1, &stmt, nil) == SQLITE_OK else { return [] }
        var out: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW { out.append(Self.text(stmt, 0)) }
        return out
    }

    /// Rewrite the whole ordering for one instance after a drag-reorder.
    @discardableResult
    func reorderThinkingRules(instanceId: String, orderedIds: [String]) -> Bool {
        guard let db else { return false }
        Self.exec(db: db, "BEGIN IMMEDIATE")
        for (idx, id) in orderedIds.enumerated() {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, "UPDATE provider_thinking_rules SET sort_order = ? WHERE id = ? AND instance_id = ?", -1, &stmt, nil) == SQLITE_OK else {
                Self.exec(db: db, "ROLLBACK")
                return false
            }
            sqlite3_bind_int(stmt, 1, Int32(idx))
            sqlite3_bind_text(stmt, 2, id, -1, Self.SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, instanceId, -1, Self.SQLITE_TRANSIENT)
            if sqlite3_step(stmt) != SQLITE_DONE {
                Self.exec(db: db, "ROLLBACK")
                return false
            }
        }
        Self.exec(db: db, "COMMIT")
        return true
    }
}
