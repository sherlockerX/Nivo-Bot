import XCTest
@testable import Minis

/// 合并针对真实值模型验证冲突、墓碑与计时，不触碰正式账户。
final class NivoPersonalBackupMergeTests: XCTestCase {
    private func task(_ title: String, revision: Int64 = 1) -> NivoTodoTask {
        NivoTodoTask(ownerKey: "source", id: "task", title: title, revision: revision,
                     createdAt: 1, updatedAt: revision)
    }

    func testImportedRecordsAreReboundButReceiptsAreNot() throws {
        var incoming = NivoLifeState(ownerKey: "source")
        incoming.tasks = [task("Read")]
        incoming.operations["remote"] = NivoLifeOperation(request: Data(), result: Data())
        let result = try NivoPersonalBackupMerge.life(local: NivoLifeState(ownerKey: ""), incoming: incoming, owner: "")
        XCTAssertEqual(result.tasks.first?.ownerKey, "")
        XCTAssertTrue(result.operations.isEmpty)
        XCTAssertEqual(result.ownerKey, "")
    }

    func testEqualRevisionConflictDoesNotSilentlyOverwrite() throws {
        var local = NivoLifeState(ownerKey: "source")
        local.tasks = [task("Local")]
        var incoming = local
        incoming.tasks[0].title = "Other device"
        XCTAssertThrowsError(try NivoPersonalBackupMerge.life(local: local, incoming: incoming, owner: "source"))
        XCTAssertEqual(local.tasks[0].title, "Local")
    }

    func testDeletedTaskCannotBeResurrectedByBackup() throws {
        var incoming = NivoLifeState(ownerKey: "source")
        incoming.tasks = [task("Read")]
        var local = incoming
        local.tasks[0].deletedAt = 10
        local.tasks[0].revision = 2
        let result = try NivoPersonalBackupMerge.life(local: local, incoming: incoming, owner: "source")
        XCTAssertEqual(result.tasks[0].deletedAt, 10)
    }

    func testImportedRunningClockIsHistoryWithoutUnmeasuredTime() throws {
        let sample = NivoFocusClockSample(wallMs: 100_000, elapsedMs: 10, bootID: "old-device")
        var incoming = NivoLifeState(ownerKey: "source")
        incoming.focusSessions = [try NivoFocusRules.start(owner: "source", id: "focus", title: "Read",
            task: nil, mode: .pomodoro, minutes: 3, clock: sample)]
        let result = try NivoPersonalBackupMerge.life(local: NivoLifeState(ownerKey: ""), incoming: incoming, owner: "")
        let restored = try XCTUnwrap(result.focusSessions.first)
        XCTAssertEqual(restored.status, .finished)
        XCTAssertEqual(restored.elapsedMs, 0)
        XCTAssertTrue(result.focusSpans.isEmpty)
        XCTAssertFalse(restored.isActive)
    }

    func testLocalActiveTimerWinsOverItsPortablePausedCopy() throws {
        let start = NivoFocusClockSample(wallMs: 100_000, elapsedMs: 10, bootID: "device")
        var local = NivoLifeState(ownerKey: "source")
        let active = try NivoFocusRules.start(owner: "source", id: "focus", title: "Read",
            task: nil, mode: .pomodoro, minutes: 3, clock: start)
        local.focusSessions = [active]
        let paused = try NivoFocusRules.mutate(active, action: "pause", expectedRevision: 1,
            clock: NivoFocusClockSample(wallMs: 105_000, elapsedMs: 5_010, bootID: "device"), spanID: "span")
        var incoming = local
        incoming.focusSessions = [paused.session]
        incoming.focusSpans = [try XCTUnwrap(paused.span)]
        let result = try NivoPersonalBackupMerge.life(local: local, incoming: incoming, owner: "source")
        XCTAssertEqual(result.focusSessions, local.focusSessions)
        XCTAssertEqual(result.focusSpans, local.focusSpans)
    }

    /// 两台设备独立发布同一来源属于冲突，不能把各自有效的备份误报为损坏。
    func testIndependentPublishedReflectionsReturnExplicitConflict() throws {
        let local = try reflectionState(owner: "local", entryID: "local-entry", text: "Local reflection.")
        let incoming = try reflectionState(owner: "source", entryID: "remote-entry", text: "Another reflection.")
        try NivoLifeValidation.validate(local, owner: "local")
        try NivoLifeValidation.validate(incoming, owner: "source")
        XCTAssertThrowsError(try NivoPersonalBackupMerge.life(local: local, incoming: incoming, owner: "local")) {
            XCTAssertEqual($0 as? NivoLifeError, .operationConflict)
        }
        XCTAssertEqual(local.mosaic?.entries.first?.text, "Local reflection.")
        XCTAssertEqual(incoming.mosaic?.entries.first?.text, "Another reflection.")
    }

    /// 原条目和旧备份中的未发布正文同时存在时，在导入预检阶段拒绝合并。
    func testPublishedReflectionAndUnpublishedDraftConflictInEitherDirection() throws {
        let published = try reflectionState(entryID: "published", text: "Published reflection.")
        let draft = try reflectionState(entryID: nil, text: "Unpublished reflection.")
        for (local, incoming) in [(published, draft), (draft, published)] {
            XCTAssertThrowsError(try NivoPersonalBackupMerge.life(local: local, incoming: incoming, owner: "source")) {
                XCTAssertEqual($0 as? NivoLifeError, .operationConflict)
            }
        }
        XCTAssertEqual(draft.mosaic?.drafts.first?.text, "Unpublished reflection.")
    }

    /// 单个旧快照已经包含两种正文时，首次恢复到空账户也不能直接接受冲突副本。
    func testLegacyBackupWithPublishedReflectionAndDraftConflictsInEmptyAccount() throws {
        var incoming = try reflectionState(entryID: "published", text: "Published reflection.")
        let pending = try reflectionState(entryID: nil, text: "Unpublished reflection.")
        incoming.mosaic?.drafts = pending.mosaic?.drafts ?? []
        try NivoLifeValidation.validate(incoming, owner: "source")
        XCTAssertThrowsError(try NivoPersonalBackupMerge.life(local: NivoLifeState(ownerKey: "local"), incoming: incoming, owner: "local")) {
            XCTAssertEqual($0 as? NivoLifeError, .operationConflict)
        }
    }

    /// 相同条目仍能重复合并，换账户只重绑owner，不重新解释来源或稳定草稿身份。
    func testIdenticalReflectionBackupKeepsSourceAndCanRebindOwner() throws {
        let incoming = try reflectionState(entryID: "published", text: "Published reflection.")
        let rebound = try NivoPersonalBackupMerge.life(local: NivoLifeState(ownerKey: "local"), incoming: incoming, owner: "local")
        let repeated = try NivoPersonalBackupMerge.life(local: rebound, incoming: incoming, owner: "local")
        XCTAssertEqual(repeated, rebound)
        XCTAssertEqual(repeated.mosaic?.entries.first?.reflectionSessionID, "focus")
        XCTAssertEqual(repeated.mosaic?.entries.first?.ownerKey, "local")
        let draft = try reflectionState(entryID: nil, text: "Draft reflection.")
        let importedDraft = try NivoPersonalBackupMerge.life(local: NivoLifeState(ownerKey: "local"), incoming: draft, owner: "local")
        XCTAssertEqual(importedDraft.mosaic?.drafts.first?.id, NivoFocusReflectionRules.draftID(sessionID: "focus"))
        XCTAssertEqual(importedDraft.mosaic?.drafts.first?.reflectionSessionID, "focus")
        XCTAssertEqual(importedDraft.mosaic?.drafts.first?.ownerKey, "local")
    }

    /// 导入预检出错发生在installBackup之前，正式仓库与导入文件的字节均保持原状。
    @MainActor
    func testReflectionMergeConflictPreservesLiveStoreAndBackupFile() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nivo-reflection-merge-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let local = try reflectionState(owner: "local", entryID: "local-entry", text: "Local reflection.")
        let incoming = try reflectionState(owner: "source", entryID: "remote-entry", text: "Remote reflection.")
        let backupFile = directory.appendingPathComponent("incoming.json")
        let incomingData = try JSONEncoder().encode(incoming)
        try incomingData.write(to: backupFile, options: .atomic)
        let repository = NivoLifeRepository(directory: directory.appendingPathComponent("life"))
        let clock = NivoFocusClockSample(wallMs: 110_000, elapsedMs: 10_010, bootID: "device")
        let initial = try await repository.open(ownerKey: "local", clock: clock)
        let setupToken = UUID()
        _ = try await repository.beginBackup(scope: initial, token: setupToken, clock: clock)
        try await repository.installBackup(local, token: setupToken)
        await repository.endBackup(token: setupToken)
        let scope = try await repository.open(ownerKey: "local", clock: clock)
        let before = try await repository.snapshot(scope: scope, clock: clock)
        let storeFile = directory.appendingPathComponent("life")
            .appendingPathComponent(NivoFocusPreferences.ownerHash("local")).appendingPathComponent("state.json")
        let storeData = try Data(contentsOf: storeFile)
        let token = UUID()
        let lease = try await repository.beginBackup(scope: scope, token: token, clock: clock)
        do {
            let imported = try JSONDecoder().decode(NivoLifeState.self, from: Data(contentsOf: backupFile))
            let merged = try NivoPersonalBackupMerge.life(local: lease, incoming: imported, owner: "local")
            try await repository.installBackup(merged, token: token)
            XCTFail("同来源冲突必须在正式安装之前失败")
        } catch { XCTAssertEqual(error as? NivoLifeError, .operationConflict) }
        await repository.endBackup(token: token)
        let reopened = try await repository.open(ownerKey: "local", clock: clock)
        let after = try await repository.snapshot(scope: reopened, clock: clock)
        XCTAssertEqual(after, before)
        XCTAssertEqual(try Data(contentsOf: storeFile), storeData)
        XCTAssertEqual(try Data(contentsOf: backupFile), incomingData)
    }

    /// 来源会话由真实规则结算，合并夹具满足生产持久化校验。
    private func reflectionState(owner: String = "source", entryID: String?, text: String) throws -> NivoLifeState {
        let started = try NivoFocusRules.start(owner: owner, id: "focus", title: "Read", task: nil,
            mode: .stopwatch, minutes: 1,
            clock: NivoFocusClockSample(wallMs: 100_000, elapsedMs: 10, bootID: "device"))
        let finished = try NivoFocusRules.mutate(started, action: "finish", expectedRevision: 1,
            clock: NivoFocusClockSample(wallMs: 105_000, elapsedMs: 5_010, bootID: "device"), spanID: "span")
        var state = NivoLifeState(ownerKey: owner)
        state.focusSessions = [finished.session]
        state.focusSpans = [try XCTUnwrap(finished.span)]
        var mosaic = NivoMosaicState(ownerKey: owner)
        mosaic.habitDays = []
        if let entryID {
            mosaic.entries = [NivoMosaicEntry(ownerKey: owner, id: entryID, day: 0, text: text,
                taskIDs: [], focusIDs: [started.id], createdAt: 106_000, updatedAt: 106_000,
                revision: 1, reflectionSessionID: started.id)]
        } else {
            mosaic.drafts = [NivoMosaicDraft(ownerKey: owner, id: NivoFocusReflectionRules.draftID(sessionID: started.id),
                day: 0, text: text, focusIDs: [started.id], updatedAt: 106_000, reflectionSessionID: started.id)]
        }
        state.mosaic = mosaic
        return state
    }
}
