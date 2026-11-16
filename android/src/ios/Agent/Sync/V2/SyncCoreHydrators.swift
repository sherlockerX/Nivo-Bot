import Foundation

/// Per-type "how do I rebuild this from local SQLite?" + "how do I merge
/// a remote into local SQLite?" hooks. Decouples SyncCore from concrete
/// stores (ChatStore / SkillStore / ProviderConfigStore / ...).
///
/// Each store registers its hooks at app launch. SyncCore looks them up
/// by recordType when building the outbound batch and when applying
/// inbound records.
///
/// Why two separate hook surfaces (build vs merge) rather than one
/// "Syncable model"-style protocol: the build path needs to load from
/// SQLite (recordType + id → SyncedX), while the merge path takes a
/// PortableRecord and integrates it with conflict resolution. Stores
/// already have those code paths in different places (mergeRemoteX
/// methods etc.) — letting them register two separate closures is the
/// least-invasive way to plug v2 in.
@MainActor
final class SyncCoreHydrators {
    static let shared = SyncCoreHydrators()
    private init() {}

    /// "Given recordType + id, return a PortableRecord ready to push (or
    /// nil if the local row no longer exists)." Called on the SyncCore
    /// actor; implementations are free to await actor hops internally.
    // nanoMuse: 读取失败与记录不存在不同，失败必须保留待发送记录。
    typealias Builder = (_ id: String) async throws -> PortableRecord?

    /// "Given a remote PortableRecord, merge it into local SQLite using
    /// this type's conflict resolution." Should be a no-op when the
    /// record cannot be applied (e.g. unknown schema version was already
    /// filtered upstream by SyncCore).
    // nanoMuse: 新的严格写盘路径将失败传回游标屏障，旧合并器逐项迁移。
    typealias Merger = (_ record: PortableRecord) async throws -> Void

    /// "Given a record id, propagate its remote deletion locally — but
    /// honour soft-delete / tombstone rules per §3.3." Optional; if not
    /// registered, SyncCore falls back to a hard delete via direct SQL.
    // nanoMuse: 删除失败必须上传到接收屏障，不能提前确认同步游标。
    typealias DeletionApplier = (_ id: String) async throws -> Void

    private var builders: [String: Builder] = [:]
    private var mergers: [String: Merger] = [:]
    private var deleters: [String: DeletionApplier] = [:]

    func register(
        recordType: String,
        builder: Builder?,
        merger: Merger?,
        deletionApplier: DeletionApplier? = nil
    ) {
        if let b = builder { builders[recordType] = b }
        if let m = merger { mergers[recordType] = m }
        if let d = deletionApplier { deleters[recordType] = d }
    }

    // nanoMuse: 严格构建器的错误交由发送循环重试。
    func buildPortable(recordType: String, id: String) async throws -> PortableRecord? {
        guard let b = builders[recordType] else {
            // No builder yet — type is registered for read-only consumption.
            return nil
        }
        return try await b(id)
    }

    /// True when this recordType has a builder closure registered. Used by
    /// SyncCore to differentiate "local row gone (clear dirty safe)" from
    /// "no builder registered yet (must NOT clear dirty)" — see audit C3.
    func hasBuilder(recordType: String) -> Bool {
        builders[recordType] != nil
    }

    // nanoMuse: 云端修改同样等待聊天和个人文件事务，占位贯穿实际写入。
    func mergeRemote(_ record: PortableRecord) async throws {
        // Honour the same per-category upload toggle on the inbound side.
        // If the user has turned off, say, Memory Files in iCloud Sync
        // settings, this device should neither push local writes nor
        // accept remote ones — otherwise toggling off only "saves your
        // own bandwidth" while peer writes still silently land on disk.
        // SyncDeviceV2 / unknown record types pass through (same rule as
        // UploadPolicy.allowsRecordType).
        guard UploadPolicy.allowsRecordType(record.id.type) else {
            return
        }
        guard let m = mergers[record.id.type] else { return }
        let sessionTypes: Set<String> = ["SessionV2", "MessageV2", "CompactMarkerV2", "SessionFileV2"]
        var sessionID: String?
        if sessionTypes.contains(record.id.type), case .string(let value) = record.fields["sessionId"] {
            sessionID = value
        }
        let token = try await NivoCloudChatAccess.acquire(sessionID: sessionID)
        defer { if let token { NivoScheduledRunScopes.shared.endConversationEdit(token) } }
        try await m(record)
    }

    // nanoMuse: 失败由SyncCore保留旧游标，忙碌会话由删除入口等待到空闲。
    func applyRemoteDeletion(_ id: SyncRecordID) async throws {
        // Same gate as mergeRemote — a disabled category should not have
        // its local rows wiped by a remote tombstone either.
        guard UploadPolicy.allowsRecordType(id.type) else { return }
        _ = try await NivoCloudChatAccess.acquire(sessionID: nil)
        if let d = deleters[id.type] {
            try await d(id.id)
            return
        }
        // No-op fallback. Stores that don't register a deletion applier
        // get default-keep behavior (the record stays locally), which is
        // safe but not necessarily what the type wants. SyncCore logs the
        // gap so the omission is visible at runtime.
    }

    var registeredRecordTypes: [String] {
        Array(Set(builders.keys).union(mergers.keys).union(deleters.keys)).sorted()
    }
}
