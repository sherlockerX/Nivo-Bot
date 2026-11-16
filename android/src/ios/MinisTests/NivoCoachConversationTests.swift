import XCTest
@testable import Minis

/// 真实SQLite验证专题的幂等创建、系统分组归属和删除后的防复活。
@MainActor
final class NivoCoachConversationTests: XCTestCase {
    private func store() throws -> ChatStore {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("coach-chat-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: folder) }
        return ChatStore(baseURL: folder)
    }

    private func request(owner: String = "one", topic: String = "topic") -> NivoCoachChatCreation {
        NivoCoachChatCreation(id: NivoCoachConversationIdentity.conversation(owner: owner, topicID: topic),
                             title: "Boundaries", modelID: "test-model", modelBinding: nil,
                             folderID: NivoCoachConversationIdentity.folder(owner: owner),
                             folderName: "Daily practice", memoryEnabled: false)
    }

    func testConversationIdentityIncludesAccountAndUnambiguousTopic() {
        let first = NivoCoachConversationIdentity.conversation(owner: "a", topicID: "b:c")
        XCTAssertNotNil(UUID(uuidString: first))
        XCTAssertEqual(first, NivoCoachConversationIdentity.conversation(owner: "a", topicID: "b:c"))
        XCTAssertNotEqual(first, NivoCoachConversationIdentity.conversation(owner: "a:b", topicID: "c"))
        XCTAssertNotEqual(first, NivoCoachConversationIdentity.conversation(owner: "other", topicID: "b:c"))
    }

    func testRetryReusesConversationAndPreservesUserEdits() async throws {
        let database = try store()
        let input = request()
        let first = try await database.nmEnsureCoachConversation(input)
        await database.updateSessionTitle(first.id, title: "My title")
        let second = try await database.nmEnsureCoachConversation(input)
        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(second.title, "My title")
        let sessions = await database.listSessions()
        let folders = await database.listFolders()
        let extras = await database.getSessionExtras(first.id)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(folders.count, 1)
        XCTAssertEqual(second.folderId, folders.first?.id)
        XCTAssertFalse(extras.memoryEnabled)
    }

    func testRoutineConversationUsesSeparateSystemGroupAndSurvivesRetry() async throws {
        let database = try store()
        var input = request()
        input = NivoManagedChatCreation(id: input.id, title: "Morning task", modelID: input.modelID,
            modelBinding: input.modelBinding, folderID: NivoRoutineConversationRules.folder(owner: "test"),
            folderName: "Scheduled tasks", memoryEnabled: false)
        let first = try await database.nmEnsureRoutineConversation(input)
        await database.updateSessionTitle(first.id, title: "My task history")
        let retry = try await database.nmEnsureRoutineConversation(input)
        XCTAssertEqual(first.id, retry.id)
        XCTAssertEqual(retry.title, "My task history")
        XCTAssertEqual(retry.source, NivoRoutineConversationRules.source)
        let folders = await database.listFolders()
        XCTAssertEqual(folders.first(where: { $0.id == input.folderID })?.origin, NivoRoutineConversationRules.source)
        do {
            _ = try await database.nmEnsureCoachConversation(input)
            XCTFail("教练不能接管定时任务创建的会话")
        } catch { XCTAssertTrue(error is NivoCoachConversationError) }
    }

    func testManualGroupWithSameNameKeepsItsIdentity() async throws {
        let database = try store()
        let manual = await database.createFolder(name: "Daily practice")
        let session = try await database.nmEnsureCoachConversation(request())
        let folders = await database.listFolders()
        XCTAssertNotEqual(session.folderId, manual.id)
        XCTAssertEqual(folders.first(where: { $0.id == manual.id })?.origin, "manual")
        XCTAssertEqual(folders.first(where: { $0.id == session.folderId })?.name, "Daily practice (2)")
    }

    func testDeletedConversationCannotBeRecreatedByOpeningRetry() async throws {
        let database = try store()
        let input = request()
        _ = try await database.nmEnsureCoachConversation(input)
        try await database.deleteSession(input.id)
        do {
            _ = try await database.nmEnsureCoachConversation(input)
            XCTFail("已删除专题不能被旧请求重新创建")
        } catch { XCTAssertTrue(error is NivoCoachConversationError) }
        let exists = await database.sessionExists(id: input.id)
        XCTAssertFalse(exists)
    }

    func testUnavailableDatabaseDoesNotReportDeletedEvidence() async throws {
        let database = try store()
        let session = try await database.nmEnsureCoachConversation(request())
        await database.closeDatabase()
        do {
            _ = try await database.nmCoachSources(chatSessionID: session.id, identifiers: ["source"])
            XCTFail("数据库关闭时必须抛错，不能回报会话或原话已删除")
        } catch { XCTAssertNotNil(error as? CocoaError) }
    }

    func testEvidenceReadDistinguishesDeletedMessageAndDeletedConversation() async throws {
        let database = try store()
        let session = try await database.nmEnsureCoachConversation(request())
        let row = RawMessage(id: "source", sessionId: session.id, role: .user,
                             parts: [.text("我的选择")], createdAt: Date())
        await database.appendMessage(row)
        let original = try await database.nmCoachSources(chatSessionID: session.id, identifiers: [row.id])
        XCTAssertTrue(original.sessionExists)
        XCTAssertEqual(original.messages[row.id]?.text, "我的选择")
        try await database.deleteMessages(sessionId: session.id)
        let deletedMessage = try await database.nmCoachSources(chatSessionID: session.id, identifiers: [row.id])
        XCTAssertTrue(deletedMessage.sessionExists)
        XCTAssertTrue(deletedMessage.messages.isEmpty)
        try await database.deleteSession(session.id)
        let deletedConversation = try await database.nmCoachSources(chatSessionID: session.id, identifiers: [row.id])
        XCTAssertFalse(deletedConversation.sessionExists)
    }

    func testEditingSourceChangesItsEvidenceDigest() async throws {
        let database = try store()
        let session = try await database.nmEnsureCoachConversation(request())
        let row = RawMessage(id: "source", sessionId: session.id, role: .assistant,
                             parts: [.text("请解释这个选择")], createdAt: Date())
        await database.appendMessage(row)
        let original = try await database.nmCoachSources(chatSessionID: session.id, identifiers: [row.id])
        try await database.updateMessageParts(messageId: row.id, parts: [.text("请举出不同的例子")])
        let edited = try await database.nmCoachSources(chatSessionID: session.id, identifiers: [row.id])
        XCTAssertNotEqual(original.messages[row.id]?.digest, edited.messages[row.id]?.digest)
        XCTAssertEqual(edited.messages[row.id]?.text, "请举出不同的例子")
    }

    func testStrictSourceWriteRejectsDuplicateAndRollsBackBeforeNextWrite() async throws {
        let database = try store()
        let session = try await database.nmEnsureCoachConversation(request())
        let row = RawMessage(id: "first", sessionId: session.id, role: .user,
                             parts: [.text("原始回答")], createdAt: Date())
        try await database.nmAppendCoachMessage(row)
        do {
            try await database.nmAppendCoachMessage(row)
            XCTFail("重复主键写入必须失败")
        } catch { XCTAssertNotNil(error as? CocoaError) }
        let next = RawMessage(id: "second", sessionId: session.id, role: .assistant,
                              parts: [.text("具体讲解")], createdAt: Date())
        try await database.nmAppendCoachMessage(next)
        let sources = try await database.nmCoachSources(chatSessionID: session.id, identifiers: [row.id, next.id])
        XCTAssertEqual(sources.messages.count, 2)
        XCTAssertEqual(sources.messages[row.id]?.text, "原始回答")
        XCTAssertEqual(sources.messages[next.id]?.sortOrder, 1)
    }

    func testStrictSourceWriteRejectsMissingParentAndClosedDatabase() async throws {
        let database = try store()
        let row = RawMessage(id: "orphan", sessionId: "missing", role: .user,
                             parts: [.text("不能成为孤儿来源")], createdAt: Date())
        do {
            try await database.nmAppendCoachMessage(row)
            XCTFail("父会话不存在时不能插入来源")
        } catch { XCTAssertNotNil(error as? NivoCoachConversationError) }
        await database.closeDatabase()
        do {
            try await database.nmAppendCoachMessage(row)
            XCTFail("数据库关闭时不能假报成功")
        } catch { XCTAssertNotNil(error as? CocoaError) }
    }
}
