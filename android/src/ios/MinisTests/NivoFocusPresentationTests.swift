import XCTest
@testable import Minis

/// 使用真实显示规则与隔离偏好域，复现普通计时及未绑定会话的背景错误。
final class NivoFocusPresentationTests: XCTestCase {
    func testCountdownShowsRemainingTimeOnBothSurfaces() throws {
        let session = try makeSession()
        let later = NivoFocusClockSample(wallMs: 31_000, elapsedMs: 30_500, bootID: "boot")
        XCTAssertEqual(NivoFocusPresentationRules.displayedDuration(session, clock: later), 150_000)
    }

    func testUnboundAISessionDoesNotUseSelectedPhoto() throws {
        try withDefaults { defaults in
            NivoFocusPreferences.setBackground(UUID().uuidString, owner: "local", defaults: defaults)
            XCTAssertEqual(NivoFocusPreferences.background(forSession: "ai-session", owner: "local", defaults: defaults), "")
        }
    }

    func testChangingNextPhotoPreservesBoundSessionAndDefaultChoice() throws {
        try withDefaults { defaults in
            let first = UUID().uuidString
            let next = UUID().uuidString
            NivoFocusPreferences.setBackground(first, owner: "local", defaults: defaults)
            NivoFocusPreferences.bindBackground(first, sessionID: "first", owner: "local", defaults: defaults)
            NivoFocusPreferences.setBackground(next, owner: "local", defaults: defaults)
            XCTAssertEqual(NivoFocusPreferences.background(forSession: "first", owner: "local", defaults: defaults), first)
            XCTAssertEqual(NivoFocusPreferences.background(owner: "local", defaults: defaults), next)
            XCTAssertEqual(NivoFocusPreferences.background(forSession: "other", owner: "local", defaults: defaults), "")
            NivoFocusPreferences.bindBackground("", sessionID: "default", owner: "local", defaults: defaults)
            XCTAssertEqual(NivoFocusPreferences.background(forSession: "default", owner: "local", defaults: defaults), "")
        }
    }

    func testDeletingBoundPhotoClearsReferenceWithoutReplacingItWithNextPhoto() throws {
        try withDefaults { defaults in
            let removed = UUID().uuidString
            let next = UUID().uuidString
            NivoFocusPreferences.bindBackground(removed, sessionID: "session", owner: "local", defaults: defaults)
            NivoFocusPreferences.setBackground(next, owner: "local", defaults: defaults)
            NivoFocusPreferences.rememberImmersive("session", owner: "local", defaults: defaults)
            NivoFocusPreferences.removeBackground(removed, owner: "local", defaults: defaults)
            XCTAssertEqual(NivoFocusPreferences.background(forSession: "session", owner: "local", defaults: defaults), "")
            XCTAssertEqual(NivoFocusPreferences.background(owner: "local", defaults: defaults), next)
            XCTAssertEqual(NivoFocusPreferences.immersiveSession(owner: "local", defaults: defaults), "session")
            NivoFocusPreferences.removeBackground(next, owner: "local", defaults: defaults)
            XCTAssertEqual(NivoFocusPreferences.background(owner: "local", defaults: defaults), "")
        }
    }

    func testAccountPreferencesStaySeparateAndRemovalPreservesOtherAccount() throws {
        try withDefaults { defaults in
            let photo = UUID().uuidString
            for owner in ["local", "other"] {
                NivoFocusPreferences.setBackground(photo, owner: owner, defaults: defaults)
                NivoFocusPreferences.bindBackground(photo, sessionID: owner, owner: owner, defaults: defaults)
                NivoFocusPreferences.rememberImmersive(owner, owner: owner, defaults: defaults)
            }
            NivoFocusPreferences.setKeepAwake(true, owner: "local", defaults: defaults)
            XCTAssertFalse(NivoFocusPreferences.keepAwake(owner: "other", defaults: defaults))
            NivoFocusPreferences.remove(owner: "local", defaults: defaults)
            XCTAssertEqual(NivoFocusPreferences.background(owner: "local", defaults: defaults), "")
            XCTAssertEqual(NivoFocusPreferences.background(forSession: "local", owner: "local", defaults: defaults), "")
            XCTAssertEqual(NivoFocusPreferences.immersiveSession(owner: "local", defaults: defaults), "")
            XCTAssertFalse(NivoFocusPreferences.keepAwake(owner: "local", defaults: defaults))
            XCTAssertEqual(NivoFocusPreferences.background(forSession: "other", owner: "other", defaults: defaults), photo)
            XCTAssertEqual(NivoFocusPreferences.immersiveSession(owner: "other", defaults: defaults), "other")
        }
    }

    func testLateCloseDoesNotClearNewSessionOrAnotherAccount() throws {
        try withDefaults { defaults in
            NivoFocusPreferences.rememberImmersive("new", owner: "local", defaults: defaults)
            NivoFocusPreferences.rememberImmersive("old", owner: "other", defaults: defaults)
            NivoFocusPreferences.dismissImmersive("old", owner: "local", defaults: defaults)
            XCTAssertEqual(NivoFocusPreferences.immersiveSession(owner: "local", defaults: defaults), "new")
            NivoFocusPreferences.dismissImmersive("new", owner: "local", defaults: defaults)
            XCTAssertEqual(NivoFocusPreferences.immersiveSession(owner: "local", defaults: defaults), "")
            XCTAssertEqual(NivoFocusPreferences.immersiveSession(owner: "other", defaults: defaults), "old")
        }
    }

    func testLegacyGlobalPreferenceMigratesOnlyAfterOwnerValidation() throws {
        try withDefaults { defaults in
            let session = try makeSession()
            let photo = UUID().uuidString
            defaults.set(session.id, forKey: "nivo.focus.immersive")
            defaults.set(true, forKey: "nivo.focus.keepAwake")
            NivoFocusPreferences.setBackground(photo, owner: "local", defaults: defaults)
            XCTAssertNil(NivoFocusPreferences.restorableSession(owner: "other", sessions: [session], defaults: defaults))
            XCTAssertEqual(defaults.string(forKey: "nivo.focus.immersive"), session.id)
            XCTAssertEqual(NivoFocusPreferences.restorableSession(owner: "local", sessions: [session], defaults: defaults), session.id)
            XCTAssertNil(defaults.object(forKey: "nivo.focus.immersive"))
            XCTAssertNil(defaults.object(forKey: "nivo.focus.keepAwake"))
            XCTAssertTrue(NivoFocusPreferences.keepAwake(owner: "local", defaults: defaults))
            XCTAssertEqual(NivoFocusPreferences.background(forSession: session.id, owner: "local", defaults: defaults), photo)
        }
    }

    func testMigrationDoesNotOverwriteNewAccountPreferences() throws {
        try withDefaults { defaults in
            let old = try makeSession()
            var current = old
            current.id = "new"
            let photo = UUID().uuidString
            defaults.set(old.id, forKey: "nivo.focus.immersive")
            defaults.set(true, forKey: "nivo.focus.keepAwake")
            NivoFocusPreferences.rememberImmersive(current.id, owner: "local", defaults: defaults)
            NivoFocusPreferences.bindBackground(photo, sessionID: current.id, owner: "local", defaults: defaults)
            NivoFocusPreferences.setKeepAwake(false, owner: "local", defaults: defaults)
            XCTAssertEqual(NivoFocusPreferences.restorableSession(owner: "local", sessions: [old, current], defaults: defaults), current.id)
            XCTAssertEqual(NivoFocusPreferences.background(forSession: current.id, owner: "local", defaults: defaults), photo)
            XCTAssertFalse(NivoFocusPreferences.keepAwake(owner: "local", defaults: defaults))
        }
    }

    func testRestorationRequiresExistingOwnedRecordAndAllowsCompletion() throws {
        try withDefaults { defaults in
            var session = try makeSession()
            NivoFocusPreferences.rememberImmersive(session.id, owner: "local", defaults: defaults)
            XCTAssertNil(NivoFocusPreferences.restorableSession(owner: "local", sessions: [], defaults: defaults))
            session.ownerKey = "other"
            XCTAssertNil(NivoFocusPreferences.restorableSession(owner: "local", sessions: [session], defaults: defaults))
            session.ownerKey = "local"
            session.deletedAt = 2_000
            XCTAssertNil(NivoFocusPreferences.restorableSession(owner: "local", sessions: [session], defaults: defaults))
            session.deletedAt = nil
            session.status = .finished
            XCTAssertEqual(NivoFocusPreferences.restorableSession(owner: "local", sessions: [session], defaults: defaults), session.id)
        }
    }

    func testPauseStopwatchBreakAndCompletionUseTheirOwnDisplayRules() throws {
        let later = NivoFocusClockSample(wallMs: 31_000, elapsedMs: 30_500, bootID: "boot")
        var session = try makeSession()
        session.status = .paused
        session.elapsedMs = 42_000
        XCTAssertEqual(NivoFocusPresentationRules.displayedDuration(session, clock: later), 138_000)
        session.status = .finished
        XCTAssertEqual(NivoFocusPresentationRules.displayedDuration(session, clock: later), 42_000)
        XCTAssertEqual(NivoFocusPresentationRules.displayedDuration(try makeSession(mode: .stopwatch), clock: later), 30_000)
        XCTAssertEqual(NivoFocusPresentationRules.displayedDuration(try makeSession(mode: .rest), clock: later), 150_000)
    }

    func testReconciliationWaitsForExpiryOrRebootAndIgnoresNonRunningRecords() throws {
        var session = try makeSession()
        let before = NivoFocusClockSample(wallMs: 31_000, elapsedMs: 30_500, bootID: "boot")
        let due = NivoFocusClockSample(wallMs: 181_000, elapsedMs: 180_500, bootID: "boot")
        let reboot = NivoFocusClockSample(wallMs: 31_000, elapsedMs: 10, bootID: "next-boot")
        XCTAssertFalse(NivoFocusPresentationRules.needsReconciliation(session, clock: before))
        XCTAssertTrue(NivoFocusPresentationRules.needsReconciliation(session, clock: due))
        XCTAssertTrue(NivoFocusPresentationRules.needsReconciliation(session, clock: reboot))
        session.status = .paused
        XCTAssertFalse(NivoFocusPresentationRules.needsReconciliation(session, clock: due))
        session.status = .finished
        XCTAssertFalse(NivoFocusPresentationRules.needsReconciliation(session, clock: reboot))
        session.status = .running
        session.deletedAt = 1
        XCTAssertFalse(NivoFocusPresentationRules.needsReconciliation(session, clock: due))
    }

    private func makeSession(mode: NivoFocusMode = .pomodoro) throws -> NivoFocusSession {
        try NivoFocusRules.start(owner: "local", id: "session", title: "Read", task: nil,
            mode: mode, minutes: 3, clock: NivoFocusClockSample(wallMs: 1_000, elapsedMs: 500, bootID: "boot"))
    }

    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "NivoFocusPresentationTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }
}
