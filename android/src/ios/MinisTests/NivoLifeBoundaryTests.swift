import XCTest
@testable import Minis

/// 真实仓库和注入故障验证账户退出、计时恢复以及损坏文件边界。
@MainActor
final class NivoLifeBoundaryTests: XCTestCase {
    private func folder() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nivo-boundary-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func clock(_ elapsed: Int64) -> NivoFocusClockSample {
        NivoFocusClockSample(wallMs: 1_000_000 + elapsed, elapsedMs: elapsed, bootID: "boot")
    }

    func testFailedSignOutSettlementDoesNotCountTimeWhileSignedOut() async throws {
        let writer = NivoFaultWriter()
        let repository = NivoLifeRepository(directory: try folder(), writer: writer.write)
        let scope = try await repository.open(ownerKey: "one", clock: clock(0))
        _ = try await repository.startFocus(title: "Read", mode: .pomodoro, minutes: 25,
                                            operationID: "start", scope: scope, clock: clock(0))
        writer.setFailure(true)
        do { try await repository.close(clock: clock(10_000)); XCTFail("应报告磁盘失败") }
        catch { XCTAssertTrue(error is CocoaError) }
        writer.setFailure(false)
        let reopened = try await repository.open(ownerKey: "one", clock: clock(100_000))
        let saved = try await repository.snapshot(scope: reopened, clock: clock(100_000))
        XCTAssertEqual(saved.focusSessions.first?.elapsedMs, 10_000)
        XCTAssertEqual(saved.focusSessions.first?.status, .paused)
        XCTAssertEqual(saved.focusSpans.map(\.durationMs), [10_000])
    }

    func testDeadlineRefreshReturnsCommittedSnapshotRevision() async throws {
        let repository = NivoLifeRepository(directory: try folder())
        let scope = try await repository.open(ownerKey: "one", clock: clock(0))
        _ = try await repository.startFocus(title: "Read", mode: .pomodoro, minutes: 1,
                                            operationID: "start", scope: scope, clock: clock(0))
        let before = try await repository.snapshot(scope: scope, clock: clock(1_000))
        let finished = try await repository.snapshot(scope: scope, clock: clock(61_000))
        XCTAssertEqual(finished.focusSessions.first?.status, .finished)
        XCTAssertGreaterThan(finished.storeRevision ?? 0, before.storeRevision ?? 0)
        let again = try await repository.snapshot(scope: scope, clock: clock(80_000))
        XCTAssertEqual(again, finished)
    }

    func testRevokedBackgroundImportCannotRecreateAccountFolder() async throws {
        let directory = try folder()
        let store = NivoFocusBackgroundStore(directory: directory)
        let scope = NivoLifeScope(ownerKey: "one", generation: 1)
        await store.bind(scope: scope)
        await store.revoke()
        do {
            _ = try await store.add(Data(), scope: scope)
            XCTFail("旧导入权限必须失效")
        } catch { XCTAssertEqual(error as? NivoLifeError, .accountChanged) }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    func testCorruptFileIsPreservedAndDoesNotBecomeEmptyState() async throws {
        let directory = try folder()
        let owner = "one"
        let accountDirectory = directory.appendingPathComponent(NivoFocusPreferences.ownerHash(owner))
        try FileManager.default.createDirectory(at: accountDirectory, withIntermediateDirectories: true)
        let file = accountDirectory.appendingPathComponent("state.json")
        let original = Data("{broken".utf8)
        try original.write(to: file)
        let repository = NivoLifeRepository(directory: directory)
        do { _ = try await repository.open(ownerKey: owner, clock: clock(0)); XCTFail("损坏数据必须拒绝载入") }
        catch { XCTAssertEqual(error as? NivoLifeError, .corruptStore) }
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    func testUnmeasuredFocusDurationIsRejected() throws {
        var state = NivoLifeState(ownerKey: "one")
        var timer = try NivoFocusRules.start(owner: "one", id: "timer", title: "Read", task: nil,
                                            mode: .pomodoro, minutes: 25, clock: clock(0))
        timer.elapsedMs = 60_000
        state.focusSessions = [timer]
        XCTAssertThrowsError(try NivoLifeValidation.validate(state, owner: "one"))
    }

    func testLocalCalendarDaySurvivesDaylightSavingBoundary() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let formatter = ISO8601DateFormatter()
        let first = try XCTUnwrap(formatter.date(from: "2026-03-08T06:30:00Z"))
        let second = try XCTUnwrap(formatter.date(from: "2026-03-08T07:30:00Z"))
        let day = NivoLifeDay.value(first, timeZone: zone)
        XCTAssertEqual(day, NivoLifeDay.value(second, timeZone: zone))
        XCTAssertEqual(day, NivoLifeDay.value(NivoLifeDay.date(day, timeZone: zone), timeZone: zone))
    }
}

/// 锁保护的故障注入器跨actor使用，测试不依赖不确定的等待时序。
private final class NivoFaultWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var shouldFail = false

    func setFailure(_ value: Bool) {
        lock.lock()
        defer { lock.unlock() }
        shouldFail = value
    }

    func write(_ data: Data, to url: URL) throws {
        lock.lock()
        let failure = shouldFail
        lock.unlock()
        if failure { throw CocoaError(.fileWriteOutOfSpace) }
        try data.write(to: url, options: .atomic)
    }
}
