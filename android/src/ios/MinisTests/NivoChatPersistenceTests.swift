import SQLite3
import XCTest
@testable import Minis

/// 使用独立SQLite文件验证分支复制与归档失败回滚，不触碰正式聊天和学习进度。
@MainActor
final class NivoChatPersistenceTests: XCTestCase {
    /// 已确认消息不重复解码，新的未确认消息仍使用严格正文校验。
    func testRelayUploadSkipsAlreadyAcknowledgedBodyDecoding() async throws {
        let (store, root) = try fixture()
        let source = try await session(in: store)
        try await store.nmAppendCoachMessage(RawMessage(id: "known", sessionId: source.id,
            role: .user, parts: [.text("已同步")], createdAt: Date()))
        try await store.nmAppendCoachMessage(RawMessage(id: "new", sessionId: source.id,
            role: .user, parts: [.text("新消息")], createdAt: Date()))
        try execute("UPDATE messages SET parts_json = '[{}]' WHERE id = 'known'", at: root)
        let pending = try await store.nmRelayMessages(sessionID: source.id, excludingKnown: ["known"])
        XCTAssertEqual(pending.map(\.id), ["new"])
    }

    /// 数据库actor接手前已经取消的编辑不截断正文。
    func testCancelledHistoryEditLeavesPersistedMessages() async throws {
        let (store, _) = try fixture()
        let source = try await session(in: store)
        try await store.nmAppendCoachMessage(RawMessage(id: "retain-on-cancel", sessionId: source.id,
            role: .user, parts: [.text("取消后保留")], createdAt: Date()))
        let edit = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await store.nmTruncateChat(sessionID: source.id, expectedMessageIDs: ["retain-on-cancel"], retainedMessageIDs: [])
        }
        do { try await edit.value; XCTFail("取消后不得继续写入") }
        catch { XCTAssertTrue(error is CancellationError) }
        let rows = await store.loadMessages(sessionId: source.id)
        XCTAssertEqual(rows.map(\.id), ["retain-on-cancel"])
    }

    /// 主聊天清空后仍保留会话，游标重放不会删除之后写入的新原话。
    func testRelayMainDeletionReplaysWithoutRemovingNewHistory() async throws {
        let (store, _) = try fixture()
        let source = try await session(in: store)
        try await store.nmAppendCoachMessage(RawMessage(id: "before-clear", sessionId: source.id,
            role: .user, parts: [.text("旧内容")], createdAt: Date()))
        try await store.nmApplyRelayConversationDeletion(sessionID: source.id, conversationID: "relay-main",
            preservesSession: true, deletedAt: 100)
        let retained = await store.getSession(source.id)
        let cleared = await store.loadMessages(sessionId: source.id)
        XCTAssertEqual(retained?.modelId, source.modelId)
        XCTAssertTrue(cleared.isEmpty)
        try await store.nmAppendCoachMessage(RawMessage(id: "after-clear", sessionId: source.id,
            role: .user, parts: [.text("新内容")], createdAt: Date()))
        try await store.nmApplyRelayConversationDeletion(sessionID: source.id, conversationID: "relay-main",
            preservesSession: true, deletedAt: 100)
        let replayed = await store.loadMessages(sessionId: source.id)
        XCTAssertEqual(replayed.map(\.id), ["after-clear"])
    }

    /// 单条撤销摘要写入失败时，不能先将删除发送给其他设备。
    func testSummaryRevertFailureKeepsMarkerAndDirtyQueue() async throws {
        let (store, root) = try fixture()
        let source = try await session(in: store)
        await store.insertCompactMarker(CompactMarker(id: "revert-summary", sessionId: source.id,
            summary: "保留的摘要", firstKeptSortOrder: 0, compactedCount: 1, createdAt: Date(),
            uiBoundarySortOrder: nil, boundaryMessageId: nil, firstKeptMessageId: nil,
            lastCompactedMessageId: nil, version: 1))
        await store.setSyncZoneName("fixture-zone")
        let before = await store.countDirtyRecords()
        try execute("CREATE TRIGGER fail_revert BEFORE DELETE ON compact_markers BEGIN SELECT RAISE(ABORT, 'fixture'); END", at: root)
        do { try await store.deleteCompactMarker(id: "revert-summary", sessionID: source.id); XCTFail("删除失败必须抛错") }
        catch { XCTAssertTrue(error is NivoSQLiteWriteError) }
        let after = await store.countDirtyRecords()
        let marker = await store.getCompactMarker(id: "revert-summary")
        XCTAssertNotNil(marker)
        XCTAssertEqual(before.total, after.total)
    }

    /// 创建失败必须传播；同一预留身份重试只生成一个会话。
    func testRelayReservedConversationRetriesAfterRealInsertFailure() async throws {
        let (store, root) = try fixture()
        let request = NivoRelayChatSQL.Session(id: UUID().uuidString, title: "中继标题", modelID: "fixture-model",
            createdAt: 1, updatedAt: 2, memoryEnabled: false, mayCreate: true, updatesTitle: true, onlyIfUntitled: false)
        try execute("CREATE TRIGGER fail_relay_create BEFORE INSERT ON sessions BEGIN SELECT RAISE(ABORT, 'fixture'); END", at: root)
        do { _ = try await store.nmEnsureRelayConversation(request); XCTFail("插入失败不能返回会话") }
        catch { XCTAssertTrue(error is NivoSQLiteWriteError) }
        let missing = await store.getSession(request.id)
        XCTAssertNil(missing)
        try execute("DROP TRIGGER fail_relay_create", at: root)
        let first = try await store.nmEnsureRelayConversation(request)
        let replay = try await store.nmEnsureRelayConversation(request)
        let identifiers = try await store.nmAccountSessionIDs()
        XCTAssertEqual(first, .inserted)
        XCTAssertEqual(replay, .unchanged)
        XCTAssertEqual(identifiers, [request.id])
    }

    /// 坏正文不能被上传路径当成零消息，再向其他设备发送删除。
    func testRelayStrictReadRejectsMalformedLocalBody() async throws {
        let (store, root) = try fixture()
        let source = try await session(in: store)
        try await store.nmAppendCoachMessage(RawMessage(id: "preserved", sessionId: source.id,
            role: .user, parts: [.text("仍需保留")], createdAt: Date()))
        try execute("UPDATE messages SET parts_json = '[{}]' WHERE id = 'preserved'", at: root)
        do { _ = try await store.nmRelayMessages(sessionID: source.id); XCTFail("坏正文必须拒绝同步") }
        catch { XCTAssertTrue(error is DecodingError) }
        let identifiers = try await store.nmAccountSessionIDs()
        XCTAssertTrue(identifiers.contains(source.id))
    }

    /// 已关闭的数据库属于读取失败，不能代表空会话。
    func testRelayReadFromClosedDatabaseThrows() async throws {
        let (store, _) = try fixture()
        await store.closeDatabase()
        do { _ = try await store.nmRelayMessages(sessionID: "missing"); XCTFail("不可读不能当作空历史") }
        catch { XCTAssertTrue(error is CocoaError) }
    }

    /// 标题同步的脏记录失败时，标题和时间共同回滚。
    func testRelayTitleFailurePreservesSavedMetadata() async throws {
        let (store, root) = try fixture()
        let identifier = UUID().uuidString
        let first = NivoRelayChatSQL.Session(id: identifier, title: "原题", modelID: "fixture-model",
            createdAt: 1, updatedAt: 2, memoryEnabled: false, mayCreate: true, updatesTitle: true, onlyIfUntitled: false)
        _ = try await store.nmEnsureRelayConversation(first)
        await store.setSyncZoneName("fixture-zone")
        try execute("CREATE TRIGGER fail_relay_dirty BEFORE INSERT ON sync_dirty_records BEGIN SELECT RAISE(ABORT, 'fixture'); END", at: root)
        let updated = NivoRelayChatSQL.Session(id: identifier, title: "新题", modelID: "fixture-model",
            createdAt: 1, updatedAt: 3, memoryEnabled: false, mayCreate: false, updatesTitle: true, onlyIfUntitled: false)
        do { _ = try await store.nmEnsureRelayConversation(updated); XCTFail("标记失败不能单独提交标题") }
        catch { XCTAssertTrue(error is NivoSQLiteWriteError) }
        let saved = await store.getSession(identifier)
        XCTAssertEqual(saved?.title, "原题")
        XCTAssertEqual(saved?.updatedAt.timeIntervalSince1970, 2)
    }

    /// 清空失败不能丢失原话或已经保存的摘要，也不能提前写入同步删除。
    func testLocalClearFailurePreservesMessagesMarkersAndCloudQueue() async throws {
        let (store, root) = try fixture()
        let source = try await session(in: store)
        try await store.nmAppendCoachMessage(RawMessage(id: "original", sessionId: source.id,
            role: .user, parts: [.text("原话")], createdAt: Date()))
        let marker = CompactMarker(id: "context", sessionId: source.id, summary: "旧上下文",
            firstKeptSortOrder: 0, compactedCount: 1, createdAt: Date(), uiBoundarySortOrder: nil,
            boundaryMessageId: nil, firstKeptMessageId: nil, lastCompactedMessageId: "original", version: 2)
        try await store.mergeRemoteCompactMarker(marker)
        await store.setSyncZoneName("fixture-zone")
        let before = await store.countDirtyRecords().total
        try execute("CREATE TRIGGER fail_clear BEFORE DELETE ON compact_markers BEGIN SELECT RAISE(ABORT, 'fixture'); END", at: root)
        do { try await store.deleteMessages(sessionId: source.id); XCTFail("清空失败必须传播") }
        catch { XCTAssertTrue(error is NivoSQLiteWriteError) }
        let rows = await store.loadMessages(sessionId: source.id)
        let retainedMarker = await store.getCompactMarker(id: "context")
        let after = await store.countDirtyRecords().total
        XCTAssertEqual(rows.map(\.id), ["original"])
        XCTAssertNotNil(retainedMarker)
        XCTAssertEqual(after, before)
    }

    /// 裁剪工具块复用原始ContentPart，保留前置工具的签名，失败与后续删除共同回滚。
    func testToolTrimPreservesStoredMetadataAndRollsBackFailedRewrite() async throws {
        let (store, root) = try fixture()
        let source = try await session(in: store)
        let retainedTool = ContentPart.toolUse(ToolUse(toolUseId: "kept-tool", name: "fixture", input: "{}",
            description: nil, thoughtSignature: "preserved-signature"))
        let cutTool = ContentPart.toolUse(ToolUse(toolUseId: "cut-tool", name: "fixture", input: "{}",
            description: nil, thoughtSignature: nil))
        let parts: [ContentPart] = [.text("保留的分析"), retainedTool, cutTool]
        try await store.nmAppendCoachMessage(RawMessage(id: "answer", sessionId: source.id,
            role: .assistant, parts: parts, createdAt: Date(timeIntervalSince1970: 1)))
        try await store.nmAppendCoachMessage(RawMessage(id: "later", sessionId: source.id,
            role: .user, parts: [.text("后续原话")], createdAt: Date(timeIntervalSince1970: 2)))
        try execute("CREATE TRIGGER fail_trim BEFORE UPDATE ON messages BEGIN SELECT RAISE(ABORT, 'fixture'); END", at: root)
        do {
            try await store.nmTruncateChat(sessionID: source.id, expectedMessageIDs: ["answer", "later"],
                retainedMessageIDs: ["answer"], trimmedToolUseID: "cut-tool")
            XCTFail("改写失败必须恢复后续消息")
        } catch { XCTAssertTrue(error is NivoSQLiteWriteError) }
        let unchanged = await store.loadMessages(sessionId: source.id)
        XCTAssertEqual(unchanged.map(\.id), ["answer", "later"])
        XCTAssertEqual(unchanged.first?.parts, parts)
        try execute("DROP TRIGGER fail_trim", at: root)
        try await store.nmTruncateChat(sessionID: source.id, expectedMessageIDs: ["answer", "later"],
            retainedMessageIDs: ["answer"], trimmedToolUseID: "cut-tool")
        let trimmed = await store.loadMessages(sessionId: source.id)
        XCTAssertEqual(trimmed.map(\.id), ["answer"])
        XCTAssertEqual(trimmed.first?.parts, [.text("保留的分析"), retainedTool])
    }

    /// 删除失败必须保留附件目录，不能仅依靠SQL回滚后再展示已经丢失的文件。
    func testLocalSessionDeletionFailureKeepsMediaAndCanRetry() async throws {
        let (store, root) = try fixture()
        let source = try await session(in: store)
        let data = Data([1, 2, 3])
        let media = await store.saveMedia(data: data, mimeType: "image/png", sessionId: source.id)
        try await store.nmAppendCoachMessage(RawMessage(id: "original", sessionId: source.id,
            role: .user, parts: [.mediaRef(media)], createdAt: Date()))
        try execute("CREATE TRIGGER fail_parent BEFORE DELETE ON sessions BEGIN SELECT RAISE(ABORT, 'fixture'); END", at: root)
        do { try await store.deleteSession(source.id); XCTFail("会话删除失败必须传播") }
        catch { XCTAssertTrue(error is NivoSQLiteWriteError) }
        let parent = await store.getSession(source.id)
        let bytes = await store.loadMediaData(media)
        XCTAssertNotNil(parent)
        XCTAssertEqual(bytes, data)
        try execute("DROP TRIGGER fail_parent", at: root)
        try await store.deleteSession(source.id)
        let deleted = await store.getSession(source.id)
        XCTAssertNil(deleted)
    }

    /// 中继传来的会话身份必须与大小写UUID的真实来源一致。
    func testRelayDeletionCannotRemoveAnotherSessionsUppercaseMessage() async throws {
        let (store, _) = try fixture()
        let source = try await session(in: store)
        let other = try await session(in: store)
        let identifier = UUID().uuidString
        try await store.nmAppendCoachMessage(RawMessage(id: identifier, sessionId: other.id,
            role: .user, parts: [.text("其他会话")], createdAt: Date()))
        do {
            try await store.nmDeleteRelayMessage(messageID: identifier.lowercased(), sessionID: source.id)
            XCTFail("跨会话删除必须拒绝")
        } catch { XCTAssertEqual(error as? NivoCloudChatSQLError, .messageOwnerChanged) }
        let rows = await store.loadMessages(sessionId: other.id)
        XCTAssertEqual(rows.map(\.id), [identifier])
    }

    private func fixture() throws -> (ChatStore, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = ChatStore(baseURL: root)
        addTeardownBlock { await store.closeDatabase(); try FileManager.default.removeItem(at: root) }
        return (store, root)
    }

    private func session(in store: ChatStore) async throws -> ChatSession {
        let identifier = UUID().uuidString
        let binding = SessionModelBinding(sessionId: identifier, primarySource: .directEntry(modelEntryId: "fixture"), subModelSource: nil)
        return try await store.nmEnsureCoachConversation(NivoCoachChatCreation(id: identifier, title: "Fixture",
            modelID: "fixture-model", modelBinding: String(decoding: try JSONEncoder().encode(binding), as: UTF8.self),
            folderID: UUID().uuidString, folderName: "Fixture", memoryEnabled: false))
    }

    private func execute(_ sql: String, at root: URL) throws {
        var database: OpaquePointer?
        guard sqlite3_open(root.appendingPathComponent("minis.db").path, &database) == SQLITE_OK else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { sqlite3_close(database) }
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
    }

    /// 真正的ContentPart解码与数据库完成标记一起验收，失败后仍可重试。
    func testStartupBackfillFailureRollsBackRealMessagesAndCompletion() async throws {
        let (store, root) = try fixture()
        let identifier = UUID().uuidString
        let remote = ChatSession(id: identifier, title: "待回填", category: nil, modelId: "fixture-model",
            createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 2))
        try await store.upsertRemoteSession(remote, deviceId: "fixture-device")
        let body = String(decoding: try JSONEncoder().encode([ContentPart.text("完整原话")]), as: UTF8.self)
        try await store.upsertRemoteMessage(id: "legacy-message", deviceId: "fixture-device", sessionId: identifier,
            role: "user", partsJson: body, createdAt: Date(timeIntervalSince1970: 1),
            tokenUsageJson: nil, sortOrder: 0, reasoningContent: nil, streamInterruptCount: 0)
        let pending = try await store.nmLegacyBackfillSessionIDs()
        XCTAssertEqual(pending, [identifier])
        try execute("CREATE TRIGGER fail_backfill BEFORE INSERT ON messages BEGIN SELECT RAISE(ABORT, 'fixture'); END", at: root)
        do {
            _ = try await store.backfillRemoteToLocal(expectedSessionIDs: pending)
            XCTFail("回填消息失败必须拒绝完成迁移")
        } catch { XCTAssertTrue(error is NivoSQLiteWriteError) }
        let failedParent = await store.getSession(identifier)
        XCTAssertNil(failedParent)
        try execute("DROP TRIGGER fail_backfill", at: root)
        let completed = try await store.backfillRemoteToLocal(expectedSessionIDs: pending)
        XCTAssertEqual(completed.sessions, 1)
        XCTAssertEqual(completed.messages, 1)
        let messages = await store.loadMessages(sessionId: identifier)
        XCTAssertEqual(messages.first?.parts, [.text("完整原话")])
        let replay = try await store.backfillRemoteToLocal(expectedSessionIDs: [])
        XCTAssertTrue(replay.alreadyCompleted)
    }

    /// 参考消息入口拒绝合法JSON但不符合ContentPart结构的正文，不能留下空会话。
    func testReferenceMessageDecoderRejectsMalformedContentBeforeWriting() async throws {
        let (store, _) = try fixture()
        do {
            try await store.upsertRemoteMessage(id: "bad", deviceId: "fixture-device", sessionId: "bad-chat",
                role: "assistant", partsJson: "[{}]", createdAt: Date(timeIntervalSince1970: 1),
                tokenUsageJson: nil, sortOrder: 0, reasoningContent: nil, streamInterruptCount: 0)
            XCTFail("真实正文解码必须失败")
        } catch { XCTAssertTrue(error is DecodingError) }
        let references = await store.listRemoteSessions(deviceId: "fixture-device")
        XCTAssertTrue(references.isEmpty)
    }

    /// 当前纯消息ID协议也能识别整会话级联，只清理参考而保留本机消息。
    func testLegacyWholeSessionCascadeKeepsLocalMessageForCurrentRecordName() async throws {
        let (store, _) = try fixture()
        let source = try await session(in: store)
        let parts = [ContentPart.text("本机保留")]
        try await store.nmAppendCoachMessage(RawMessage(id: "retained", sessionId: source.id,
            role: .user, parts: parts, createdAt: Date(timeIntervalSince1970: 1)))
        try await store.upsertRemoteMessage(id: "retained", deviceId: "fixture-device", sessionId: source.id,
            role: "user", partsJson: String(decoding: try JSONEncoder().encode(parts), as: UTF8.self),
            createdAt: Date(timeIntervalSince1970: 1), tokenUsageJson: nil, sortOrder: 0,
            reasoningContent: nil, streamInterruptCount: 0)
        let identity = try NivoCloudReferenceSQL.MessageIdentity(recordName: "Message:retained")
        let owner = try await store.nmLegacyMessageSession(id: identity.id, deviceID: "fixture-device")
        XCTAssertEqual(owner, source.id)
        try await store.nmDeleteLegacyMessage(identity, deviceID: "fixture-device",
            expectedSessionID: owner, preservingSessions: [source.id])
        let local = await store.loadMessages(sessionId: source.id)
        let remote = await store.loadRemoteMessages(sessionId: source.id, deviceId: "fixture-device")
        XCTAssertEqual(local.first?.parts, parts)
        XCTAssertTrue(remote.isEmpty)
    }

    /// 共享协议会话删除会清理参考，延迟消息和启动回填都不能重建它。
    func testSharedSessionDeletionCannotBeResurrectedByLegacyReference() async throws {
        let (store, _) = try fixture()
        let source = try await session(in: store)
        let body = String(decoding: try JSONEncoder().encode([ContentPart.text("旧副本")]), as: UTF8.self)
        try await store.upsertRemoteMessage(id: "old", deviceId: "fixture-device", sessionId: source.id,
            role: "user", partsJson: body, createdAt: Date(timeIntervalSince1970: 1),
            tokenUsageJson: nil, sortOrder: 0, reasoningContent: nil, streamInterruptCount: 0)
        _ = try await store.nmApplyRemoteChatDeletion(recordType: "SessionV2", id: source.id, expectedSessionID: source.id)
        try await store.upsertRemoteMessage(id: "old", deviceId: "fixture-device", sessionId: source.id,
            role: "user", partsJson: body, createdAt: Date(timeIntervalSince1970: 1),
            tokenUsageJson: nil, sortOrder: 0, reasoningContent: nil, streamInterruptCount: 0)
        let result = try await store.backfillRemoteToLocal(expectedSessionIDs: [])
        XCTAssertEqual(result.sessions, 0)
        XCTAssertEqual(result.messages, 0)
        let parent = await store.getSession(source.id)
        XCTAssertNil(parent)
    }

    /// 旧消息补入失败必须与标题修改共同回滚，重试后才发布完整会话。
    func testInboundSessionBackfillFailureRollsBackMetadataAndCanRetry() async throws {
        let (store, root) = try fixture()
        let source = try await session(in: store)
        let body = String(decoding: try JSONEncoder().encode([ContentPart.text("完整旧消息")]), as: UTF8.self)
        try await store.upsertRemoteMessage(id: "pending", deviceId: "fixture-device", sessionId: source.id,
            role: "user", partsJson: body, createdAt: Date(timeIntervalSince1970: 10),
            tokenUsageJson: nil, sortOrder: 0, reasoningContent: nil, streamInterruptCount: 0)
        try execute("CREATE TRIGGER fail_backfill BEFORE INSERT ON messages BEGIN SELECT RAISE(ABORT, 'fixture'); END", at: root)
        var incoming = source
        incoming.title = "远端新标题"
        incoming.updatedAt = source.updatedAt.addingTimeInterval(100)
        do {
            try await store.mergeRemoteSession(incoming, fromDeviceId: "fixture-device")
            XCTFail("补入失败必须传播")
        } catch { XCTAssertTrue(error is NivoSQLiteWriteError) }
        let failed = await store.getSession(source.id)
        let failedMessages = await store.loadMessages(sessionId: source.id)
        XCTAssertEqual(failed?.title, source.title)
        XCTAssertEqual(failed?.updatedAt, source.updatedAt)
        XCTAssertTrue(failedMessages.isEmpty)
        try execute("DROP TRIGGER fail_backfill", at: root)
        try await store.mergeRemoteSession(incoming, fromDeviceId: "fixture-device")
        let restored = await store.getSession(source.id)
        let messages = await store.loadMessages(sessionId: source.id)
        XCTAssertEqual(restored?.title, "远端新标题")
        XCTAssertEqual(messages.first?.parts, [.text("完整旧消息")])
    }

    /// 旧协议参考表中的损坏正文不能重新进入教练证据或清空已显示的会话标题。
    func testInboundSessionMalformedBackfillPreservesExistingConversation() async throws {
        let (store, root) = try fixture()
        let source = try await session(in: store)
        // 入口已拒绝坏正文，用SQL保留真实历史损坏数据的迁移场景。
        try execute("""
            INSERT INTO remote_messages(id, device_id, session_id, role, parts_json, created_at)
            VALUES ('invalid', 'fixture-device', '\(source.id)', 'assistant', 'broken', 1)
            """, at: root)
        var incoming = source
        incoming.title = "不能保存"
        incoming.updatedAt = source.updatedAt.addingTimeInterval(100)
        do {
            try await store.mergeRemoteSession(incoming, fromDeviceId: "fixture-device")
            XCTFail("坏正文必须拒绝")
        } catch { XCTAssertTrue(error is DecodingError) }
        let preserved = await store.getSession(source.id)
        let messages = await store.loadMessages(sessionId: source.id)
        XCTAssertEqual(preserved?.title, source.title)
        XCTAssertTrue(messages.isEmpty)
    }

    /// 同步中使用另一会话的消息ID，不能替换教练正在引用的用户原话。
    func testInboundMessageRejectsAnotherConversationOwner() async throws {
        let (store, _) = try fixture()
        let first = try await session(in: store)
        let second = try await session(in: store)
        try await store.nmAppendCoachMessage(RawMessage(id: "evidence", sessionId: first.id,
            role: .user, parts: [.text("原话")], createdAt: Date(timeIntervalSince1970: 1)))
        let body = String(decoding: try JSONEncoder().encode([ContentPart.text("其他会话的回答")]), as: UTF8.self)
        do {
            try await store.mergeRemoteMessage(id: "evidence", sessionId: second.id, role: "user",
                partsJson: body, createdAt: Date(), tokenUsageJson: nil, sortOrder: 0,
                reasoningContent: nil, streamInterruptCount: 0, updatedAt: Date().addingTimeInterval(100))
            XCTFail("跨会话ID必须拒绝")
        } catch { XCTAssertEqual(error as? NivoCloudChatSQLError, .messageOwnerChanged) }
        let original = await store.loadMessages(sessionId: first.id)
        let other = await store.loadMessages(sessionId: second.id)
        XCTAssertEqual(original.first?.parts, [.text("原话")])
        XCTAssertTrue(other.isEmpty)
    }

    /// 坏JSON不能被当作空消息写入，也不能改变已有证据版本。
    func testInboundMalformedBodyAndUsageLeaveOriginalAnswer() async throws {
        let (store, _) = try fixture()
        let source = try await session(in: store)
        try await store.nmAppendCoachMessage(RawMessage(id: "answer", sessionId: source.id,
            role: .assistant, parts: [.text("完整回答")], createdAt: Date(timeIntervalSince1970: 1)))
        for (body, usage) in [("broken", String?.none), ("[]", "broken")] {
            do {
                try await store.mergeRemoteMessage(id: "answer", sessionId: source.id, role: "assistant",
                    partsJson: body, createdAt: Date(), tokenUsageJson: usage, sortOrder: 0,
                    reasoningContent: nil, streamInterruptCount: 0, updatedAt: Date().addingTimeInterval(100))
                XCTFail("坏正文或用量必须拒绝")
            } catch { XCTAssertTrue(error is DecodingError) }
        }
        let original = await store.loadMessages(sessionId: source.id)
        XCTAssertEqual(original.first?.parts, [.text("完整回答")])
    }

    func testInboundFolderDeleteFailurePreservesDailyPracticeGrouping() async throws {
        let (store, root) = try fixture()
        let source = try await session(in: store)
        let saved = await store.getSession(source.id)
        let folderID = try XCTUnwrap(saved?.folderId)
        try execute("CREATE TRIGGER fail_inbound_folder BEFORE DELETE ON folders BEGIN SELECT RAISE(ABORT, 'fixture'); END", at: root)
        do {
            try await store.applyRemoteFolderDeletion(id: folderID)
            XCTFail("分组删除失败必须传播")
        } catch { XCTAssertTrue(error is NivoSQLiteWriteError) }
        let after = await store.getSession(source.id)
        let folder = await store.getFolder(folderID)
        XCTAssertEqual(after?.folderId, folderID)
        XCTAssertNotNil(folder)
    }

    func testInboundMessageInsertFailureRollsBackLocalSortOrder() async throws {
        let (store, root) = try fixture()
        let source = try await session(in: store)
        try await store.nmAppendCoachMessage(RawMessage(id: "later", sessionId: source.id,
            role: .user, parts: [.text("原话")], createdAt: Date(timeIntervalSince1970: 10)))
        let before = await store.loadMessages(sessionId: source.id)
        try execute("CREATE TRIGGER fail_inbound_insert BEFORE INSERT ON messages BEGIN SELECT RAISE(ABORT, 'fixture'); END", at: root)
        do {
            try await store.mergeRemoteMessage(id: "earlier", sessionId: source.id, role: "user",
                partsJson: "[]", createdAt: Date(timeIntervalSince1970: 1), tokenUsageJson: nil, sortOrder: 0,
                reasoningContent: nil, streamInterruptCount: 0)
            XCTFail("正文插入失败必须撤销排序调整")
        } catch { XCTAssertTrue(error is NivoSQLiteWriteError) }
        let after = await store.loadMessages(sessionId: source.id)
        XCTAssertEqual(after.map(\.id), before.map(\.id))
        XCTAssertEqual(after.map(\.sortOrder), before.map(\.sortOrder))
    }

    func testInboundMarkerFailureKeepsPreviousContextWithoutRequeueingSync() async throws {
        let (store, root) = try fixture()
        let source = try await session(in: store)
        await store.setSyncZoneName("fixture-zone")
        let original = CompactMarker(id: "context", sessionId: source.id, summary: "旧上下文",
            firstKeptSortOrder: 1, compactedCount: 1, createdAt: Date(timeIntervalSince1970: 1),
            uiBoundarySortOrder: nil, boundaryMessageId: nil, firstKeptMessageId: nil,
            lastCompactedMessageId: "answer", version: 2)
        try await store.mergeRemoteCompactMarker(original)
        let beforeDirty = await store.countDirtyRecords()
        try execute("CREATE TRIGGER fail_inbound_marker BEFORE UPDATE ON compact_markers BEGIN SELECT RAISE(ABORT, 'fixture'); END", at: root)
        let replacement = CompactMarker(id: "context", sessionId: source.id, summary: "新上下文",
            firstKeptSortOrder: 2, compactedCount: 2, createdAt: Date(timeIntervalSince1970: 2),
            uiBoundarySortOrder: nil, boundaryMessageId: nil, firstKeptMessageId: nil,
            lastCompactedMessageId: "later", version: 2)
        do { try await store.mergeRemoteCompactMarker(replacement); XCTFail("摘要失败必须传播") }
        catch { XCTAssertTrue(error is NivoSQLiteWriteError) }
        let saved = await store.getCompactMarker(id: "context")
        let afterDirty = await store.countDirtyRecords()
        XCTAssertEqual(saved?.summary, "旧上下文")
        XCTAssertEqual(saved?.lastCompactedMessageId, "answer")
        XCTAssertEqual(afterDirty.total, beforeDirty.total)
        XCTAssertNil(beforeDirty.byType["CompactMarkerV2"])
    }

    /// 构造真实同步输入，应用事务仍调用生产ChatStore，不使用数据库替身。
    private func cloudRecords(sessionID: String, messageID: String = "remote") throws -> [PortableRecord] {
        let date = Date(timeIntervalSince1970: 1_000)
        let parts = String(decoding: try JSONEncoder().encode([ContentPart.text("云端回答")]), as: UTF8.self)
        return [
            PortableRecord(id: SyncRecordID(type: "SessionV2", id: sessionID),
                fields: ["sessionId": .string(sessionID)], updatedAt: date),
            PortableRecord(id: SyncRecordID(type: "MessageV2", id: messageID), fields: [
                "messageId": .string(messageID), "sessionId": .string(sessionID), "role": .string("assistant"),
                "partsJson": .string(parts), "createdAt": .date(date), "sortOrder": .int(14)
            ], updatedAt: date)
        ]
    }

    func testForcePullInsertFailurePreservesLocalRowsAttachmentsAndDirtyQueue() async throws {
        let (store, root) = try fixture()
        let source = try await session(in: store)
        await store.setSyncZoneName("fixture-zone")
        let bytes = Data([3, 2, 1])
        let media = await store.saveMedia(data: bytes, mimeType: "image/png", sessionId: source.id)
        try await store.nmAppendCoachMessage(RawMessage(id: "local", sessionId: source.id, role: .user,
            parts: [.mediaRef(media)], createdAt: Date()))
        let dirtyBefore = await store.countDirtyRecords().total
        try execute("CREATE TRIGGER fail_pull BEFORE INSERT ON messages WHEN NEW.id = 'remote' BEGIN SELECT RAISE(ABORT, 'fixture'); END", at: root)
        let snapshot = try NivoCloudSessionSnapshot(sessionID: source.id, records: cloudRecords(sessionID: source.id))
        do { _ = try await store.nmReplaceCloudSession(snapshot); XCTFail("插入失败必须回滚删除") }
        catch { XCTAssertTrue(error is CocoaError) }
        let rows = await store.loadMessages(sessionId: source.id)
        let saved = await store.loadMediaData(media)
        let dirtyAfter = await store.countDirtyRecords().total
        XCTAssertEqual(rows.map(\.id), ["local"])
        XCTAssertEqual(saved, bytes)
        XCTAssertEqual(dirtyAfter, dirtyBefore)
    }

    func testForcePullPreservesLocalConversationBindingAndAttribution() async throws {
        let (store, _) = try fixture()
        let source = try await session(in: store)
        var original = RawMessage(id: "remote", sessionId: source.id, role: .assistant,
            parts: [.text("本机旧回答")], createdAt: Date())
        original.modelId = "measured-model"
        original.providerType = "openAI"
        try await store.nmAppendCoachMessage(original)
        let before = await store.getSessionExtras(source.id)
        let snapshot = try NivoCloudSessionSnapshot(sessionID: source.id, records: cloudRecords(sessionID: source.id))
        let replaced = try await store.nmReplaceCloudSession(snapshot)
        let parent = await store.getSession(source.id)
        let after = await store.getSessionExtras(source.id)
        let rows = await store.loadMessages(sessionId: source.id)
        XCTAssertEqual(replaced, 1)
        XCTAssertEqual(parent?.folderId, source.folderId)
        XCTAssertEqual(parent?.source, source.source)
        XCTAssertEqual(after.modelBinding, before.modelBinding)
        XCTAssertEqual(after.memoryEnabled, before.memoryEnabled)
        XCTAssertEqual(rows.first?.parts, [.text("云端回答")])
        XCTAssertEqual(rows.first?.modelId, "measured-model")
        XCTAssertEqual(rows.first?.providerType, "openAI")
        XCTAssertEqual(rows.first?.sortOrder, 0)
    }

    func testForcePullRejectsMessageIdentifierOwnedByAnotherSession() async throws {
        let (store, _) = try fixture()
        let source = try await session(in: store)
        let other = try await session(in: store)
        try await store.nmAppendCoachMessage(RawMessage(id: "remote", sessionId: other.id, role: .user,
            parts: [.text("其他会话原文")], createdAt: Date()))
        let snapshot = try NivoCloudSessionSnapshot(sessionID: source.id, records: cloudRecords(sessionID: source.id))
        do { _ = try await store.nmReplaceCloudSession(snapshot); XCTFail("不得抢占其他会话消息") }
        catch { XCTAssertTrue(error is NivoLifeError) }
        let rows = await store.loadMessages(sessionId: other.id)
        XCTAssertEqual(rows.first?.parts, [.text("其他会话原文")])
    }

    func testForcePullRejectsMissingParentDuplicateForeignAndUnreadablePayload() throws {
        let records = try cloudRecords(sessionID: "s")
        XCTAssertThrowsError(try NivoCloudSessionSnapshot(sessionID: "s", records: [records[1]]))
        XCTAssertThrowsError(try NivoCloudSessionSnapshot(sessionID: "s", records: records + [records[1]]))
        XCTAssertThrowsError(try NivoCloudSessionSnapshot(sessionID: "other", records: records))
        var fields = records[1].fields
        fields["partsJson"] = .string("corrupt")
        let invalid = PortableRecord(id: records[1].id, fields: fields, updatedAt: Date())
        XCTAssertThrowsError(try NivoCloudSessionSnapshot(sessionID: "s", records: [records[0], invalid]))
    }

    func testBranchDoesNotCountSystemContinuationAsAUserTurn() throws {
        let rows = [
            RawMessage(id: "ask", sessionId: "s", role: .user, parts: [.text("问题")], createdAt: Date()),
            RawMessage(id: "reminder", sessionId: "s", role: .user, parts: [.text("<system-reminder>continue</system-reminder>")], createdAt: Date()),
            RawMessage(id: "reply", sessionId: "s", role: .assistant, parts: [.text("回答")], createdAt: Date()),
            RawMessage(id: "next", sessionId: "s", role: .user, parts: [.text("另一个问题")], createdAt: Date())
        ]
        XCTAssertEqual(try NivoChatBranchRules.prefix(rows, userTurns: 1).map(\.id), ["ask", "reminder", "reply"])
        XCTAssertThrowsError(try NivoChatBranchRules.prefix(rows, userTurns: 3))
        XCTAssertThrowsError(try NivoChatBranchRules.prefix(rows, userTurns: 0))
    }

    func testBranchKeepsModelMemoryAndMessageSnapshotsWithoutDuplicatingUsage() async throws {
        let (store, _) = try fixture()
        let source = try await session(in: store)
        try await store.nmAppendCoachMessage(RawMessage(id: "ask", sessionId: source.id, role: .user,
            parts: [.text("问题")], createdAt: Date()))
        var response = RawMessage(id: "reply", sessionId: source.id, role: .assistant,
            parts: [.text("回答")], createdAt: Date(), reasoningContent: "reason", streamInterruptCount: 2)
        response.modelId = "actual-model"
        response.modelDisplayName = "Actual model"
        response.providerType = "openAI"
        response.providerInstanceId = "fixture-instance"
        response.errorInfo = "interrupted"
        response.tokenUsage = StoredTokenUsage(inputTokens: 3, outputTokens: 5, cacheCreationTokens: 0, cacheReadTokens: 0)
        try await store.nmAppendCoachMessage(response)
        try await store.nmAppendCoachMessage(RawMessage(id: "later", sessionId: source.id, role: .user,
            parts: [.text("后续问题")], createdAt: Date()))
        let branchID = try await store.nmCreateBranch(sourceID: source.id, branchID: UUID().uuidString, userTurns: 1, title: "Branch")
        let branch = await store.getSession(branchID)
        let extras = await store.getSessionExtras(branchID)
        let copied = await store.loadMessages(sessionId: branchID)
        XCTAssertEqual(branch?.modelId, source.modelId)
        XCTAssertNil(branch?.folderId)
        XCTAssertEqual(branch?.source, "branch")
        XCTAssertFalse(extras.memoryEnabled)
        let binding = try JSONDecoder().decode(SessionModelBinding.self, from: Data(try XCTUnwrap(extras.modelBinding).utf8))
        XCTAssertEqual(binding.sessionId, branchID)
        XCTAssertEqual(binding.primarySource, .directEntry(modelEntryId: "fixture"))
        XCTAssertEqual(copied.count, 2)
        XCTAssertEqual(copied.last?.modelId, "actual-model")
        XCTAssertEqual(copied.last?.errorInfo, "interrupted")
        XCTAssertEqual(copied.last?.reasoningContent, "reason")
        XCTAssertEqual(copied.last?.streamInterruptCount, 2)
        XCTAssertNil(copied.last?.tokenUsage)
        XCTAssertTrue(Set(copied.map(\.id)).isDisjoint(with: ["ask", "reply", "later"]))
    }

    func testBranchMediaSurvivesDeletingTheSource() async throws {
        let (store, _) = try fixture()
        let source = try await session(in: store)
        let content = Data([1, 2, 3, 4])
        let media = await store.saveMedia(data: content, mimeType: "image/png", sessionId: source.id)
        try await store.nmAppendCoachMessage(RawMessage(id: "photo", sessionId: source.id, role: .user,
            parts: [.mediaRef(media)], createdAt: Date()))
        let branchID = try await store.nmCreateBranch(sourceID: source.id, branchID: UUID().uuidString, userTurns: 1, title: "Branch")
        let copied = await store.loadMessages(sessionId: branchID)
        guard case .mediaRef(let reference) = try XCTUnwrap(copied.first?.parts.first) else {
            return XCTFail("图片引用必须保留")
        }
        XCTAssertNotEqual(reference.relativePath, media.relativePath)
        try await store.deleteSession(source.id)
        let saved = await store.loadMediaData(reference)
        XCTAssertEqual(saved, content)
    }

    func testSessionUpdateFailureRollsBackTheSourceMessage() async throws {
        let (store, root) = try fixture()
        let source = try await session(in: store)
        try execute("CREATE TRIGGER fail_touch BEFORE UPDATE ON sessions BEGIN SELECT RAISE(ABORT, 'fixture'); END", at: root)
        do {
            try await store.nmAppendCoachMessage(RawMessage(id: "failed", sessionId: source.id, role: .user,
                parts: [.text("不能假报已保存")], createdAt: Date()))
            XCTFail("会话写入失败必须回滚整个事务")
        } catch { XCTAssertTrue(error is CocoaError) }
        let rows = await store.loadMessages(sessionId: source.id)
        XCTAssertTrue(rows.isEmpty)
    }

    func testFailedBranchLeavesNoPlaceholderSession() async throws {
        let (store, root) = try fixture()
        let source = try await session(in: store)
        try await store.nmAppendCoachMessage(RawMessage(id: "ask", sessionId: source.id, role: .user,
            parts: [.text("问题")], createdAt: Date()))
        let target = UUID().uuidString
        try execute("CREATE TRIGGER fail_branch BEFORE INSERT ON messages WHEN NEW.session_id = '\(target)' BEGIN SELECT RAISE(ABORT, 'fixture'); END", at: root)
        do {
            _ = try await store.nmCreateBranch(sourceID: source.id, branchID: target, userTurns: 1, title: "Branch")
            XCTFail("分支写入失败必须回滚占位会话")
        } catch { XCTAssertTrue(error is CocoaError) }
        let saved = await store.getSession(target)
        let originals = await store.loadMessages(sessionId: source.id)
        XCTAssertNil(saved)
        XCTAssertEqual(originals.count, 1)
    }

    func testEvidenceLookupDoesNotReadAnotherConversation() async throws {
        let (store, _) = try fixture()
        let first = try await session(in: store)
        let other = try await session(in: store)
        try await store.nmAppendCoachMessage(RawMessage(id: "other", sessionId: other.id, role: .user,
            parts: [.text("同一句话")], createdAt: Date()))
        let sources = try await store.nmCoachSources(chatSessionID: first.id, identifiers: ["other"])
        XCTAssertTrue(sources.sessionExists)
        XCTAssertTrue(sources.messages.isEmpty)
    }

    func testBranchRemapsOnlySummariesWithinTheCopiedHistory() async throws {
        let (store, _) = try fixture()
        let source = try await session(in: store)
        for (identifier, role) in [("ask", MessageRole.user), ("reply", .assistant), ("later", .user)] {
            try await store.nmAppendCoachMessage(RawMessage(id: identifier, sessionId: source.id,
                role: role, parts: [.text(identifier)], createdAt: Date()))
        }
        for (identifier, anchor) in [("safe", "reply"), ("future", "later")] {
            await store.insertCompactMarker(CompactMarker(id: identifier, sessionId: source.id,
                summary: identifier, firstKeptSortOrder: 0, compactedCount: 2, createdAt: Date(),
                uiBoundarySortOrder: nil, boundaryMessageId: nil, firstKeptMessageId: nil,
                lastCompactedMessageId: anchor, version: 2))
        }
        let target = try await store.nmCreateBranch(sourceID: source.id, branchID: UUID().uuidString,
            userTurns: 1, title: "Branch")
        let rows = await store.loadMessages(sessionId: target)
        let markers = await store.compactMarkers(sessionId: target)
        XCTAssertEqual(markers.count, 1)
        XCTAssertEqual(markers.first?.summary, "safe")
        XCTAssertEqual(markers.first?.sessionId, target)
        XCTAssertEqual(markers.first?.lastCompactedMessageId, rows.last?.id)
        XCTAssertNotEqual(markers.first?.id, "safe")
    }

    func testSummaryWriteFailureRollsBackTheWholeBranch() async throws {
        let (store, root) = try fixture()
        let source = try await session(in: store)
        try await store.nmAppendCoachMessage(RawMessage(id: "ask", sessionId: source.id, role: .user,
            parts: [.text("问题")], createdAt: Date()))
        await store.insertCompactMarker(CompactMarker(id: "marker", sessionId: source.id, summary: "摘要",
            firstKeptSortOrder: 0, compactedCount: 1, createdAt: Date(), uiBoundarySortOrder: nil,
            boundaryMessageId: nil, firstKeptMessageId: nil, lastCompactedMessageId: "ask", version: 2))
        let target = UUID().uuidString
        try execute("CREATE TRIGGER fail_marker BEFORE INSERT ON compact_markers WHEN NEW.session_id = '\(target)' BEGIN SELECT RAISE(ABORT, 'fixture'); END", at: root)
        do {
            _ = try await store.nmCreateBranch(sourceID: source.id, branchID: target, userTurns: 1, title: "Branch")
            XCTFail("摘要写入失败不能返回缺少上下文的分支")
        } catch { XCTAssertTrue(error is CocoaError) }
        let saved = await store.getSession(target)
        let rows = await store.loadMessages(sessionId: target)
        XCTAssertNil(saved)
        XCTAssertTrue(rows.isEmpty)
    }

    func testRemoteSessionDeletionRollsBackChildrenWhenParentDeleteFails() async throws {
        let (store, root) = try fixture()
        let source = try await session(in: store)
        try await store.nmAppendCoachMessage(RawMessage(id: "original", sessionId: source.id,
            role: .user, parts: [.text("保留原话")], createdAt: Date()))
        let content = Data([1, 2, 3])
        let media = await store.saveMedia(data: content, mimeType: "image/png", sessionId: source.id)
        try execute("CREATE TRIGGER fail_remote_delete BEFORE DELETE ON sessions BEGIN SELECT RAISE(ABORT, 'fixture'); END", at: root)
        do {
            _ = try await store.nmApplyRemoteChatDeletion(recordType: "SessionV2", id: source.id, expectedSessionID: source.id)
            XCTFail("会话删除失败必须连同子消息回滚")
        } catch { XCTAssertTrue(error is NivoSQLiteWriteError) }
        let rows = await store.loadMessages(sessionId: source.id)
        let saved = await store.loadMediaData(media)
        let parent = await store.getSession(source.id)
        XCTAssertEqual(rows.map(\.id), ["original"])
        XCTAssertEqual(saved, content)
        XCTAssertNotNil(parent)
    }

    func testRemoteDeleteDoesNotQueueAnotherCloudDeletion() async throws {
        let (store, _) = try fixture()
        let source = try await session(in: store)
        try await store.nmAppendCoachMessage(RawMessage(id: "original", sessionId: source.id,
            role: .user, parts: [.text("原话")], createdAt: Date()))
        await store.setSyncZoneName("fixture-zone")
        let before = await store.countDirtyRecords()
        let removed = try await store.nmApplyRemoteChatDeletion(recordType: "SessionV2", id: source.id,
            expectedSessionID: source.id)
        let after = await store.countDirtyRecords()
        let rows = await store.loadMessages(sessionId: source.id)
        let parent = await store.getSession(source.id)
        XCTAssertTrue(removed)
        XCTAssertNil(parent)
        XCTAssertTrue(rows.isEmpty)
        XCTAssertEqual(after.total, before.total)
        let replay = try await store.nmApplyRemoteChatDeletion(recordType: "SessionV2", id: source.id,
            expectedSessionID: nil)
        XCTAssertFalse(replay)
    }

    func testRemoteMessageDeleteRejectsChangedSourceAndReplaysIdempotently() async throws {
        let (store, _) = try fixture()
        let source = try await session(in: store)
        try await store.nmAppendCoachMessage(RawMessage(id: "original", sessionId: source.id,
            role: .user, parts: [.text("不能删错会话")], createdAt: Date()))
        do {
            _ = try await store.nmApplyRemoteChatDeletion(recordType: "MessageV2", id: "original",
                expectedSessionID: UUID().uuidString)
            XCTFail("占位后来源变化必须拒绝删除")
        } catch { XCTAssertEqual(error as? NivoLifeError, .operationConflict) }
        let owner = try await store.nmRemoteChatSession(recordType: "MessageV2", id: "original")
        XCTAssertEqual(owner, source.id)
        let removed = try await store.nmApplyRemoteChatDeletion(recordType: "MessageV2", id: "original",
            expectedSessionID: owner)
        let replay = try await store.nmApplyRemoteChatDeletion(recordType: "MessageV2", id: "original",
            expectedSessionID: nil)
        XCTAssertTrue(removed)
        XCTAssertFalse(replay)
    }

    func testRemoteSourceLookupFailsWhenDatabaseIsClosed() async throws {
        let (store, _) = try fixture()
        await store.closeDatabase()
        do {
            _ = try await store.nmRemoteChatSession(recordType: "MessageV2", id: "missing")
            XCTFail("数据库不可读不能伪装成没有消息")
        } catch { XCTAssertTrue(error is CocoaError) }
    }
}
