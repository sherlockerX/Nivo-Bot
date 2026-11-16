import XCTest
@testable import Minis

/// 用独立的真实文件验证中继游标与账户映射，不能把读取失败当成空账户。
final class NivoRelaySyncStateTests: XCTestCase {
    func testNewMessageWithinSameSecondStillRequiresUploadScan() {
        let entry = NivoRelayEntry(cid: "conversation", kind: "main", pushedUpdatedAt: 10, knownMids: ["old"])
        XCTAssertTrue(entry.requiresMessageScan(present: ["old", "new"], intro: [], updatedAt: 10))
    }

    func testUnchangedHistoryDoesNotDecodeAgainButDeletionDoes() {
        let entry = NivoRelayEntry(cid: "conversation", kind: "main", pushedUpdatedAt: 10, knownMids: ["old", "intro"])
        XCTAssertFalse(entry.requiresMessageScan(present: ["old"], intro: ["intro"], updatedAt: 10))
        XCTAssertTrue(entry.requiresMessageScan(present: [], intro: ["intro"], updatedAt: 10))
    }

    func testMessageUploadAlsoRecreatesConversationAfterRelayWipe() {
        let entry = NivoRelayEntry(cid: "conversation", kind: "main", pushedTitle: "title", pushedUpdatedAt: 10, knownMids: ["old"])
        XCTAssertTrue(entry.requiresConversationUpload(title: "title", updatedAt: 10, hasMessageChanges: true))
        XCTAssertFalse(entry.requiresConversationUpload(title: "title", updatedAt: 10, hasMessageChanges: false))
    }

    func testLocalMainDeletionClearsIdentityAndOriginsWithoutTouchingOtherChat() {
        var store = NivoRelayStore(account: "account-a")
        store.entries["main"] = .init(cid: "main-cid", kind: "main", knownMids: ["old"])
        store.entries["side"] = .init(cid: "side-cid", kind: "side", knownMids: ["side-message"])
        store.mainCid = "main-cid"
        store.mainSession = "main"
        store.remoteMids = ["old": "device", "side-message": "other"]
        store.removeLocalConversation("main")
        store.removeLocalConversation("main")
        XCTAssertNil(store.mainCid)
        XCTAssertNil(store.mainSession)
        XCTAssertEqual(store.remoteMids, ["side-message": "other"])
        XCTAssertEqual(store.pendingDeletes, ["main-cid"])
        XCTAssertEqual(store.entries["side"]?.cid, "side-cid")
    }

    private func files() throws -> NivoRelaySyncFile {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return NivoRelaySyncFile(url: root.appendingPathComponent("accounts.json"),
            legacyURL: root.appendingPathComponent("legacy.json"))
    }

    func testCorruptCurrentFileIsPreservedAndBlocksFallback() throws {
        let files = try files()
        let corrupt = Data("{broken".utf8)
        try corrupt.write(to: files.url)
        try JSONEncoder().encode(NivoRelayStore(account: "account-old")).write(to: files.legacyURL)
        XCTAssertThrowsError(try files.load())
        XCTAssertEqual(try Data(contentsOf: files.url), corrupt)
    }

    func testCorruptLegacyFileIsNotImportedAsEmpty() throws {
        let files = try files()
        try Data("{broken".utf8).write(to: files.legacyURL)
        XCTAssertThrowsError(try files.load())
        XCTAssertFalse(FileManager.default.fileExists(atPath: files.url.path))
    }

    func testFailedSaveReportsErrorAndKeepsPreviousCursor() throws {
        let files = try files()
        let old = NivoRelayTables(stores: ["account-a": NivoRelayStore(account: "account-a")], current: "account-a")
        try files.save(old)
        var next = old
        next.stores["account-a"]?.cursor = 50
        // 目标目录不可替换，不能依赖当前进程是否有管理员权限制造故障。
        let blocked = files.url.deletingLastPathComponent().appendingPathComponent("blocked")
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        try Data("retain".utf8).write(to: blocked.appendingPathComponent("child"))
        let unwritable = NivoRelaySyncFile(url: blocked, legacyURL: files.legacyURL)
        XCTAssertThrowsError(try unwritable.save(next))
        XCTAssertEqual(try files.load(), old)
    }

    func testLegacyFieldsMigrateWithoutInventingKnownMessages() throws {
        let files = try files()
        try Data(#"{"account":"account-a","cursor":12,"entries":{}}"#.utf8).write(to: files.legacyURL)
        let saved = try files.load()
        XCTAssertEqual(saved.current, "account-a")
        XCTAssertEqual(saved.stores["account-a"]?.cursor, 12)
        XCTAssertEqual(saved.stores["account-a"]?.pulled, true)
        XCTAssertEqual(saved.stores["account-a"]?.deferred, [])
        try files.save(saved)
        XCTAssertEqual(try files.load(), saved)
    }

    func testAbsentFilesStartEmpty() throws {
        XCTAssertEqual(try files().load(), NivoRelayTables())
    }

    func testFailedCommitKeepsPublishedCursorAndDeferredMessages() throws {
        let files = try files()
        var state = NivoRelaySyncState()
        try state.load(from: files)
        var old = NivoRelayTables(stores: ["account-a": NivoRelayStore(account: "account-a")], current: "account-a")
        old.stores["account-a"]?.deferred = [.init(mid: "message", cid: "conversation", role: "user",
            text: "fixture", createdAt: 10, deviceName: "fixture")]
        try state.commit(old, to: files)
        var candidate = old
        candidate.stores["account-a"]?.cursor = 50
        candidate.stores["account-a"]?.deferred = []
        let unavailable = NivoRelaySyncFile(url: files.url.appendingPathComponent("missing/file"), legacyURL: files.legacyURL)
        XCTAssertThrowsError(try state.commit(candidate, to: unavailable))
        XCTAssertEqual(state.tables, old)
        XCTAssertEqual(try files.load(), old)
    }

    func testReadFailureCanRetryWithoutPublishingEmptyState() throws {
        let files = try files()
        try Data("{".utf8).write(to: files.url)
        var state = NivoRelaySyncState()
        XCTAssertThrowsError(try state.load(from: files))
        XCTAssertFalse(state.isLoaded)
        let valid = NivoRelayTables(stores: ["account-a": NivoRelayStore(account: "account-a")], current: "account-a")
        try files.save(valid)
        try state.load(from: files)
        XCTAssertTrue(state.isLoaded)
        XCTAssertEqual(state.tables, valid)
    }

    func testInvalidAccountMappingAndNegativeCursorAreRejected() throws {
        let files = try files()
        let mismatched = NivoRelayTables(stores: ["account-a": NivoRelayStore(account: "account-b")], current: "account-a")
        try JSONEncoder().encode(mismatched).write(to: files.url)
        XCTAssertThrowsError(try files.load())
        var negative = NivoRelayTables(stores: ["account-a": NivoRelayStore(account: "account-a")], current: "account-a")
        negative.stores["account-a"]?.cursor = -1
        XCTAssertThrowsError(try files.save(negative))
    }

    func testMainClearKeepsMappingAndRemovesOnlyItsMessageOrigins() throws {
        var store = NivoRelayStore(account: "account-a")
        store.entries["main"] = .init(cid: "main-cid", kind: "main", pushedTitle: "title", pushedUpdatedAt: 10, knownMids: ["message"])
        store.mainCid = "main-cid"
        store.mainSession = "main"
        store.remoteMids = ["message": "device", "other": "device"]
        store.deferred = [.init(mid: "later", cid: "main-cid", role: "user", text: "fixture", createdAt: 1, deviceName: "device")]
        store.applyConversationDeletion(cid: "main-cid", localID: "main", replacementCID: "replacement-cid")
        XCTAssertEqual(store.entries["main"]?.cid, "replacement-cid")
        XCTAssertEqual(store.entries["main"]?.knownMids, [])
        XCTAssertNil(store.entries["main"]?.pushedUpdatedAt)
        XCTAssertEqual(store.mainSession, "main")
        XCTAssertEqual(store.mainCid, "replacement-cid")
        XCTAssertEqual(store.remoteMids, ["other": "device"])
        XCTAssertTrue(store.deferred.isEmpty)
        let files = try files()
        let tables = NivoRelayTables(stores: [store.account: store], current: store.account)
        try files.save(tables)
        XCTAssertEqual(try files.load(), tables)
    }
}
