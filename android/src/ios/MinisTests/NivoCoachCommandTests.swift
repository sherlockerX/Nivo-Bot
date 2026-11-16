import XCTest
@testable import Minis

/// 直接验证真实仓库的事务、精确重试和账户范围，不用镜像状态机替代生产逻辑。
@MainActor
final class NivoCoachCommandTests: XCTestCase {
    private func store() throws -> NivoCoachV2Store {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("coach-" + UUID().uuidString.prefix(8))
        addTeardownBlock { if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) } }
        return NivoCoachV2Store(directory: folder)
    }

    private func context(_ store: NivoCoachV2Store, owner: String = "test-owner") async throws -> NivoCoachCommandContext {
        try await store.open(ownerKey: owner)
        return NivoCoachCommandContext(ownerKey: owner, generation: try await store.access(ownerKey: owner), isHost: true)
    }

    private func apply(_ action: String, to store: NivoCoachV2Store, context: NivoCoachCommandContext,
                       target: String = "", text: String = "", payload: String = "") async throws -> NivoCoachCommandResult {
        let state = try await store.snapshot(ownerKey: context.ownerKey)
        return try await store.execute(NivoCoachCommand(action: action, operationID: UUID().uuidString,
            expectedRevision: state.revision, targetID: target, text: text, payload: payload), context: context)
    }

    func testExactRetryDoesNotDuplicateDraftOrIncrementRevision() async throws {
        let repository = try store()
        let context = try await context(repository)
        let before = try await repository.snapshot()
        let command = NivoCoachCommand(action: "new_draft", operationID: "draft-retry", expectedRevision: before.revision, text: "Learn boundaries")
        let first = try await repository.execute(command, context: context)
        let second = try await repository.execute(command, context: context)
        let after = try await repository.snapshot()
        XCTAssertEqual(first.targetID, second.targetID)
        XCTAssertTrue(second.isReplaySnapshot)
        XCTAssertEqual(after.revision, before.revision + 1)
        XCTAssertEqual(after.drafts.count, 1)
    }

    func testStaleRevisionAndChangedRetryLeaveStateUntouched() async throws {
        let repository = try store()
        let context = try await context(repository)
        let before = try await repository.snapshot()
        var request = NivoCoachCommand(action: "new_draft", operationID: "draft-once", expectedRevision: before.revision, text: "First")
        _ = try await repository.execute(request, context: context)
        let saved = try await repository.snapshot()
        request.operationID = "different-operation"
        do { _ = try await repository.execute(request, context: context); XCTFail("旧版本必须拒绝") }
        catch { XCTAssertEqual(error as? NivoLifeError, .staleRevision(expected: before.revision, actual: saved.revision)) }
        request.operationID = "draft-once"
        request.text = "Changed"
        do { _ = try await repository.execute(request, context: context); XCTFail("同一操作不能换内容") }
        catch { XCTAssertEqual(error as? NivoLifeError, .operationConflict) }
        let after = try await repository.snapshot()
        XCTAssertEqual(after, saved)
    }

    func testOldAccountGenerationCannotReviveAfterReturningToAccount() async throws {
        let repository = try store()
        let old = try await context(repository)
        await repository.close()
        _ = try await context(repository)
        do { _ = try await apply("new_draft", to: repository, context: old, text: "Old request"); XCTFail("旧代次不能复活") }
        catch { XCTAssertEqual(error as? NivoLifeError, .accountChanged) }
    }

    func testPausePreservesLessonAndPendingTurn() async throws {
        let repository = try store()
        let context = try await context(repository)
        let state = try await repository.snapshot()
        let track = try XCTUnwrap(state.tracks.first { !$0.course.needsCriteriaReview })
        let topic = try await apply("start_topic", to: repository, context: context, target: track.id)
        let started = try await apply("start_lesson", to: repository, context: context, target: topic.targetID)
        _ = try await apply("pause_session", to: repository, context: context, target: started.targetID)
        let paused = try await repository.snapshot().sessions.first { $0.id == started.targetID }
        XCTAssertEqual(paused?.status, "paused")
        XCTAssertEqual(paused?.endedAt, 0)
        _ = try await apply("resume_session", to: repository, context: context, target: started.targetID)
        let resumed = try await repository.snapshot()
        XCTAssertEqual(resumed.sessions.count, 1)
        XCTAssertEqual(resumed.sessions.first?.status, "active")
    }

    func testPendingReplyBlocksNewLessonUntilOriginalArchiveIsRecovered() async throws {
        let repository = try store()
        let host = try await context(repository)
        let initial = try await repository.snapshot()
        let track = try XCTUnwrap(initial.tracks.first { !$0.course.needsCriteriaReview })
        let topic = try await apply("start_topic", to: repository, context: host, target: track.id)
        try await repository.bindTopicConversation(topicID: topic.targetID, chatSessionID: "practice",
            ownerKey: host.ownerKey, generation: host.generation)
        let started = try await apply("start_lesson", to: repository, context: host, target: topic.targetID)
        _ = try await apply("end_lesson", to: repository, context: host, target: started.targetID)
        let entry = NivoCoachArchiveEntry(ownerKey: host.ownerKey, chatID: "practice", lessonID: started.targetID,
            messageID: "saved-reply", role: "assistant", text: "这一课的最终讲解", digest: String(repeating: "a", count: 64))
        try await repository.stageArchive(entry, generation: host.generation)
        let before = try await repository.snapshot()

        do {
            _ = try await apply("start_lesson", to: repository, context: host, target: topic.targetID)
            XCTFail("上一课未归档时不能先建立下一课")
        } catch { XCTAssertEqual(error as? NivoLifeError, .invalidTransition("pending_archive")) }
        let blocked = try await repository.snapshot()
        XCTAssertTrue(blocked == before, "拒绝新课不能改变档案或保存操作回执")

        try await repository.recordConversationReply(chatSessionID: entry.chatID, messageID: entry.messageID,
            text: entry.text, expectedSessionID: entry.lessonID, ownerKey: host.ownerKey,
            generation: host.generation, sourceDigest: entry.digest)
        try await repository.finishArchive(entry, generation: host.generation)
        let next = try await apply("start_lesson", to: repository, context: host, target: topic.targetID)
        let recovered = try await repository.snapshot()
        XCTAssertNotEqual(next.targetID, started.targetID)
        XCTAssertEqual(recovered.sessions.count, 2)
        XCTAssertEqual(recovered.sessions.first?.turns.last?.originMessageID, entry.messageID)
        XCTAssertTrue(recovered.sessions.last?.turns.isEmpty == true)
    }

    func testPendingArchiveDoesNotPreventReusingCurrentLesson() async throws {
        let repository = try store()
        let host = try await context(repository)
        let initial = try await repository.snapshot()
        let track = try XCTUnwrap(initial.tracks.first { !$0.course.needsCriteriaReview })
        let topic = try await apply("start_topic", to: repository, context: host, target: track.id)
        try await repository.bindTopicConversation(topicID: topic.targetID, chatSessionID: "practice",
            ownerKey: host.ownerKey, generation: host.generation)
        let started = try await apply("start_lesson", to: repository, context: host, target: topic.targetID)
        let entry = NivoCoachArchiveEntry(ownerKey: host.ownerKey, chatID: "practice", lessonID: started.targetID,
            messageID: "saved-reply", role: "assistant", text: "等待整理的回答", digest: String(repeating: "b", count: 64))
        try await repository.stageArchive(entry, generation: host.generation)
        let reopened = try await apply("start_lesson", to: repository, context: host, target: topic.targetID)
        let snapshot = try await repository.snapshot()
        let pending = try await repository.pendingArchives(chatSessionID: "practice", ownerKey: host.ownerKey, generation: host.generation)
        XCTAssertEqual(reopened.targetID, started.targetID)
        XCTAssertEqual(snapshot.sessions.count, 1)
        XCTAssertEqual(pending.entries, [entry])
    }

    func testCorruptPendingArchiveBlocksNewLessonWithoutChangingState() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("coach-" + UUID().uuidString.prefix(8))
        addTeardownBlock { try FileManager.default.removeItem(at: folder) }
        let repository = NivoCoachV2Store(directory: folder)
        let host = try await context(repository)
        let initial = try await repository.snapshot()
        let track = try XCTUnwrap(initial.tracks.first { !$0.course.needsCriteriaReview })
        let topic = try await apply("start_topic", to: repository, context: host, target: track.id)
        try await repository.bindTopicConversation(topicID: topic.targetID, chatSessionID: "practice",
            ownerKey: host.ownerKey, generation: host.generation)
        let started = try await apply("start_lesson", to: repository, context: host, target: topic.targetID)
        _ = try await apply("end_lesson", to: repository, context: host, target: started.targetID)
        let entry = NivoCoachArchiveEntry(ownerKey: host.ownerKey, chatID: "practice", lessonID: started.targetID,
            messageID: "saved-reply", role: "assistant", text: "尚未整理的原文", digest: String(repeating: "c", count: 64))
        try await repository.stageArchive(entry, generation: host.generation)
        let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []
        let archive = try XCTUnwrap(files.first { $0.pathComponents.contains("archive-outbox") && $0.pathExtension == "json" })
        let damaged = Data("damaged-archive".utf8)
        try damaged.write(to: archive)
        let before = try await repository.snapshot()
        do {
            _ = try await apply("start_lesson", to: repository, context: host, target: topic.targetID)
            XCTFail("损坏队列不能当作空队列跳过")
        } catch { XCTAssertEqual(error as? NivoLifeError, .corruptStore) }
        let after = try await repository.snapshot()
        XCTAssertTrue(after == before, "恢复失败不能留下新课或回执")
        XCTAssertEqual(try Data(contentsOf: archive), damaged)
    }

    func testTopicScopeRejectsMainChatReceiptBeforeReplay() async throws {
        let repository = try store()
        let host = try await context(repository)
        let state = try await repository.snapshot()
        let track = try XCTUnwrap(state.tracks.first { !$0.course.needsCriteriaReview })
        let topic = try await apply("start_topic", to: repository, context: host, target: track.id)
        try await repository.bindTopicConversation(topicID: topic.targetID, chatSessionID: "practice", ownerKey: host.ownerKey, generation: host.generation)
        let revision = try await repository.snapshot().revision
        let command = NivoCoachCommand(action: "new_draft", operationID: "main-receipt", expectedRevision: revision, text: "Private goal")
        _ = try await repository.execute(command, context: host)
        let user = NivoSavedUserTurn(id: "row", text: "Private goal", ownerKey: host.ownerKey, chatSessionID: "practice", createdAt: 1)
        let scoped = NivoCoachCommandContext(ownerKey: host.ownerKey, generation: host.generation,
            chatSessionID: "practice", isMain: false, user: user)
        do { _ = try await repository.execute(command, context: scoped); XCTFail("专题不能取得主聊天回执") }
        catch { XCTAssertEqual(error as? NivoLifeError, .invalidField("coach_scope")) }
    }

    func testWriterFailureDoesNotPublishCandidateState() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("coach-failure-" + UUID().uuidString)
        addTeardownBlock { if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) } }
        let initial = NivoCoachV2Store(directory: folder)
        try await initial.open(ownerKey: "test-owner")
        let expected = try await initial.snapshot()
        await initial.close()
        let failing = NivoCoachV2Store(directory: folder, writer: { _, _ in throw CocoaError(.fileWriteOutOfSpace) })
        let context = try await context(failing)
        do { _ = try await apply("new_draft", to: failing, context: context, text: "Should roll back"); XCTFail("落盘失败必须抛错") }
        catch { XCTAssertTrue(error is CocoaError) }
        let actual = try await failing.snapshot()
        XCTAssertEqual(actual, expected)
    }

    func testPageRetryCannotReopenClosedOrDifferentAccount() async throws {
        let repository = try store()
        _ = try await context(repository, owner: "first")
        await repository.close()
        do { try await repository.retryOpen(ownerKey: "first"); XCTFail("关闭后的页面不能重开仓库") }
        catch { XCTAssertEqual(error as? NivoLifeError, .accountChanged) }
        let current = try await context(repository, owner: "second")
        _ = try await apply("new_draft", to: repository, context: current, text: "Current account")
        let expected = try await repository.snapshot(ownerKey: "second")
        do { try await repository.retryOpen(ownerKey: "first"); XCTFail("旧页面不能切换仓库账户") }
        catch { XCTAssertEqual(error as? NivoLifeError, .accountChanged) }
        let actual = try await repository.snapshot(ownerKey: "second")
        XCTAssertEqual(actual, expected)
    }

    func testPageRetryReopensRepairedArchiveWithoutReplacingOriginalOnFailure() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("coach-retry-" + UUID().uuidString)
        addTeardownBlock { if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) } }
        let repository = NivoCoachV2Store(directory: folder)
        try await repository.open(ownerKey: "test-owner")
        let expected = try await repository.snapshot()
        let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []
        let archive = try XCTUnwrap(files.first { $0.lastPathComponent == "state.json" })
        let original = try Data(contentsOf: archive)
        await repository.close()
        let damaged = Data("invalid-json".utf8)
        try damaged.write(to: archive, options: .atomic)
        do { try await repository.open(ownerKey: "test-owner"); XCTFail("损坏档案不能当作空课程") }
        catch { XCTAssertEqual(try Data(contentsOf: archive), damaged) }
        do { try await repository.retryOpen(ownerKey: "test-owner"); XCTFail("未修复前必须继续报错") }
        catch { XCTAssertEqual(try Data(contentsOf: archive), damaged) }
        try original.write(to: archive, options: .atomic)
        try await repository.retryOpen(ownerKey: "test-owner")
        let actual = try await repository.snapshot(ownerKey: "test-owner")
        XCTAssertEqual(actual, expected)
    }
}
