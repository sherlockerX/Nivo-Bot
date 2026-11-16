import XCTest
@testable import Minis

/// 备份冻结必须撤销旧写入凭证，同时不改变本机正在计时的会话。
@MainActor
final class NivoPersonalBackupBoundaryTests: XCTestCase {
    private func directory() throws -> URL {
        let result = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: result) }
        return result
    }

    private func clock(_ elapsed: Int64) -> NivoFocusClockSample {
        NivoFocusClockSample(wallMs: 1_000_000 + elapsed, elapsedMs: elapsed, bootID: "boot")
    }

    func testBackupCapturesConfirmedTimeWithoutPausingLocalTimer() async throws {
        let repository = NivoLifeRepository(directory: try directory())
        let scope = try await repository.open(ownerKey: "", clock: clock(0))
        let session = try await repository.startFocus(title: "Read", taskID: nil, mode: .pomodoro,
            minutes: 3, operationID: "start", scope: scope, clock: clock(0))
        let token = UUID()
        let snapshot = try await repository.beginBackup(scope: scope, token: token, clock: clock(5_000))
        XCTAssertEqual(snapshot.focusSessions.first?.elapsedMs, 5_000)
        XCTAssertEqual(snapshot.focusSessions.first?.status, .paused)
        XCTAssertEqual(snapshot.focusSpans.reduce(0) { $0 + $1.durationMs }, 5_000)
        do {
            _ = try await repository.controlFocus(action: "pause", id: session.id,
                expectedRevision: session.revision, operationID: "stale", scope: scope, clock: clock(6_000))
            XCTFail("冻结后旧页面不能写入")
        } catch { XCTAssertEqual(error as? NivoLifeError, .accountChanged) }
        await repository.endBackup(token: token)
        let reopened = try await repository.open(ownerKey: "", clock: clock(8_000))
        XCTAssertNotEqual(reopened, scope)
        let current = try await repository.snapshot(scope: reopened, clock: clock(8_000))
        let running = try XCTUnwrap(current.focusSessions.first)
        XCTAssertEqual(running.status, .running)
        XCTAssertEqual(NivoFocusRules.currentElapsed(running, clock: clock(8_000)), 8_000)
    }

    func testWrongLeaseCannotUnlockOrOpenFrozenRepository() async throws {
        let repository = NivoLifeRepository(directory: try directory())
        let scope = try await repository.open(ownerKey: "", clock: clock(0))
        let token = UUID()
        _ = try await repository.beginBackup(scope: scope, token: token, clock: clock(0))
        await repository.endBackup(token: UUID())
        do {
            _ = try await repository.open(ownerKey: "other", clock: clock(0))
            XCTFail("其他账户也不能在恢复途中打开仓库")
        } catch { XCTAssertTrue(error is NivoPersonalBackupError) }
        await repository.endBackup(token: token)
        _ = try await repository.open(ownerKey: "other", clock: clock(0))
    }
}
