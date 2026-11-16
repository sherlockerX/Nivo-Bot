import Foundation
import AVFoundation
import UIKit

// MARK: - AudioSessionCoordinator
//
// The SINGLE owner of AVAudioSession category/active across the app. Every
// subsystem that needs audio declares an INTENT via begin()/end(); the
// coordinator picks the highest-priority active intent and applies its session
// profile (the only place setCategory / setActive is called). This removes the
// previous "everyone calls setCategory last-wins" races and the foreground-return
// silence (a stale category survived because a partial guard skipped reconfigure).
//
// Audio sources → intents (System TTS and cloud TTS are the SAME `replyTTS`
// source, just different engines resolved from the Voice Output group):
//   .capture            — mic recording (.record/.measurement)            [highest]
//   .mediaAttachment    — Markdown audio attachment / auto_play playback
//   .replyTTS           — read-replies (cloud VoiceOutputPlayer OR System AVSpeech)
//   .backgroundKeepAlive— silent keep-alive track (background only)        [lowest]
//
// `.mediaAttachment` and `.replyTTS` are mutually exclusive at the source level
// (the media player preempts TTS — see AIChatViewModel.stopSpeech on play), so in
// practice only one of them is active; the coordinator still ranks them.

// nanoMuse: 统一管理录音、播放及双工通话的音频会话，其他组件只申报使用意图。
/// 音频会话协调器，独占管理类别、激活状态与通话扬声器路由。
@MainActor
final class AudioSessionCoordinator {
    static let shared = AudioSessionCoordinator()
    private init() { registerInterruptionObserver() }

    // nanoMuse: 通话优先级最高，允许后台队列安全传递意图值。
    enum Intent: Int, Sendable {
        // Higher rawValue = higher priority.
        case backgroundKeepAlive = 0
        case replyTTS = 1
        case mediaAttachment = 2
        case capture = 3
        case call = 4
    }

    private let logger = AppLogger(category: "AudioSession")
    private var active: Set<Intent> = []

    /// True while the mic is capturing — reply TTS is suppressed in this state.
    // nanoMuse: 双工通话也占用麦克风，普通回复朗读不得插入通话。
    var isCapturing: Bool { active.contains(.capture) || active.contains(.call) }

    // MARK: - Public API

    /// Posted when a media attachment preempts reply TTS — the active chat VM stops
    /// its System AVSpeechSynthesizer in response (cloud TTS is stopped directly).
    static let replyTTSPreemptedNotification = Notification.Name("AudioSession.replyTTSPreempted")

    /// Declare that `intent` now needs the audio session. Idempotent.
    ///
    /// The profile is applied ASYNCHRONOUSLY (see `apply`), so on return the
    /// session may not yet carry this intent's category. That is fine for
    /// playback intents but NOT for mic capture, which must read
    /// `AVAudioEngine.inputNode.inputFormat` only once `.record` is live — use
    /// `beginAndWait` there.
    func begin(_ intent: Intent) {
        beginInternal(intent)
    }

    /// [T-voice-input-double-tap] `begin` + bounded wait for the profile to
    /// actually be applied. Returns `true` if the session reached this intent's
    /// profile within `timeout`.
    ///
    /// Why this exists: reply TTS holds `.playback`, and tapping the mic while it
    /// speaks stops TTS and begins `.capture` in the same turn. Since
    /// bf9d66f6 moved `setCategory`/`setActive` onto a serial background queue
    /// (to stop a wedged mediaserverd from tripping the 10s watchdog), `begin`
    /// returns before the switch lands. The VAD then read `inputFormat` while the
    /// session was still in TTS's `.playback` profile, got 0 channels / 0 Hz, and
    /// threw "Microphone input unavailable" — so the first tap stopped the speech
    /// but never started recording. By the second tap the queue had drained and
    /// the profile was correct, which is exactly the reported "works on the
    /// second tap" behaviour.
    ///
    /// The wait is bounded and runs on the SAME serial queue the work is enqueued
    /// on, so it cannot outlive the queued block and cannot deadlock; on timeout
    /// the caller proceeds and its own 0-channel guard still protects it. The main
    /// thread is parked for at most `timeout`, well inside the watchdog budget.
    @discardableResult
    func beginAndWait(_ intent: Intent, timeout: TimeInterval = 1.0) -> Bool {
        // nanoMuse: 等待队列排空不等于配置成功，必须检查后台记录的实际结果。
        beginInternal(intent)
        guard highest == intent else { return false }
        guard Self.pendingLock.withLock({ Self.pendingApplies }) > 0 else {
            return Self.hasApplied(intent)
        }
        let sem = DispatchSemaphore(value: 0)
        Self.sessionQueue.async { sem.signal() }   // FIFO: runs after pending applies
        let hit = sem.wait(timeout: .now() + timeout) == .success
        if !hit {
            logger.error("[AudioSession] beginAndWait(\(intent)) timed out after \(timeout)s")
        }
        return hit && Self.hasApplied(intent)
    }

    // nanoMuse: 通话启动通过异步屏障等待，避免硬件会话配置阻塞主线程。
    /// 申报音频意图，等待真实配置结果并传播配置失败。
    func beginAsync(_ intent: Intent) async throws {
        beginInternal(intent)
        guard highest == intent else { throw SessionError.preempted }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            Self.sessionQueue.async {
                if Self.hasApplied(intent) {
                    continuation.resume()
                } else {
                    let error = Self.pendingLock.withLock { Self.lastApplyError }
                    continuation.resume(throwing: error ?? SessionError.configurationFailed)
                }
            }
        }
        // nanoMuse: 等待期间可能已经挂断或被更高优先级意图抢占。
        guard highest == intent, Self.hasApplied(intent) else { throw SessionError.preempted }
    }

    // nanoMuse: 通话必须等待真实激活结果，不能借用同步等待阻塞主线程。
    /// 激活最高优先级双工会话，失败时向通话层传播错误。
    @discardableResult
    func beginCall(owner: UUID = UUID()) async throws -> UUID {
        callOwner = owner
        try await beginAsync(.call)
        guard callOwner == owner else { throw SessionError.preempted }
        return owner
    }

    // nanoMuse: 旧音频队列清理完才释放意图，租约防止旧挂断关闭新通话。
    /// 仅释放指定通话持有的会话意图，过期清理请求直接忽略。
    func endCall(owner: UUID) {
        guard callOwner == owner else { return }
        end(.call)
    }

    // nanoMuse: 仅协调器修改通话路由，默认使用听筒或系统选中的耳机。
    private var isCallSpeaker = false
    // nanoMuse: 每次启动拥有独立租约，允许后台节点清理安全地延迟完成。
    private var callOwner: UUID?

    /// 切换通话扬声器，并在限定时间内确认配置成功。
    func setCallSpeaker(_ isSpeaker: Bool, timeout: TimeInterval = 1.0) throws {
        guard active.contains(.call) else { throw SessionError.preempted }
        isCallSpeaker = isSpeaker
        apply(reason: "call-speaker", force: true)
        guard beginAndWait(.call, timeout: timeout) else {
            throw Self.pendingLock.withLock { Self.lastApplyError } ?? SessionError.configurationFailed
        }
    }

    // nanoMuse: 使用明确失败值，禁止失败后继续创建输入节点。
    enum SessionError: Error, Sendable {
        case preempted
        case configurationFailed
    }

    private func beginInternal(_ intent: Intent) {
        // Media attachment preempts reply TTS (mutually exclusive voice content):
        // stop the cloud queue directly and notify the chat VM to stop System TTS,
        // BEFORE media takes the session. (TTS is not auto-resumed afterwards.)
        // nanoMuse: 通话开始前也停止普通回复朗读，防止语音混入双工链路。
        if (intent == .mediaAttachment || intent == .call), active.contains(.replyTTS) {
            VoiceOutputPlayer.shared.stopAll()
            NotificationCenter.default.post(name: Self.replyTTSPreemptedNotification, object: nil)
        }
        let was = highest
        active.insert(intent)
        // nanoMuse: 配置失败后，即使乐观状态尚未回滚，也必须允许下一次重试。
        let hasFailedApply = Self.pendingLock.withLock {
            Self.pendingApplies == 0 && Self.appliedIntent != highest
        }
        if highest != was || !sessionActive || hasFailedApply {
            apply(reason: "begin(\(intent))")
        }
    }

    /// Declare that `intent` no longer needs the session.
    func end(_ intent: Intent) {
        guard active.contains(intent) else { return }
        active.remove(intent)
        // nanoMuse: 新通话从系统默认听筒或耳机路由开始。
        if intent == .call {
            isCallSpeaker = false
            callOwner = nil
        }
        apply(reason: "end(\(intent))")
    }

    /// Re-assert the correct session on foreground return (the stale-category fix)
    /// and stop the background keep-alive track (not needed in foreground).
    func reassertForForeground() {
        active.remove(.backgroundKeepAlive)
        apply(reason: "foreground")
    }

    // MARK: - Core (the ONLY setCategory/setActive site)

    private var sessionActive = false

    private var highest: Intent? { active.max(by: { $0.rawValue < $1.rawValue }) }

    private func profile(for intent: Intent) -> (AVAudioSession.Category, AVAudioSession.Mode, AVAudioSession.CategoryOptions) {
        switch intent {
        // nanoMuse: 双工语音启用语音聊天模式和蓝牙免提，扬声器由用户选择。
        case .call:
            // nanoMuse: 切换外放只使用路由覆盖，不重复改类别而中断正在运行的引擎。
            return (.playAndRecord, .voiceChat, [.allowBluetooth])
        case .capture:
            return (.record, .measurement, [])
        case .mediaAttachment:
            return (.playback, .default, [.duckOthers])
        case .replyTTS:
            return (.playback, .spokenAudio, [.duckOthers])
        case .backgroundKeepAlive:
            return (.playback, .default, [.mixWithOthers])
        }
    }

    /// Serial queue that owns every blocking AVAudioSession mutation.
    ///
    /// [T-audiosession-setactive-watchdog] `setActive` / `setCategory` forward to
    /// mediaserverd over an NSXPCConnection and wait for a SYNCHRONOUS reply.
    /// When that daemon is wedged the reply never lands, and because this class
    /// is `@MainActor` the call was blocking the main thread — the app was
    /// SIGKILLed by the 10s scene-update watchdog (0x8BADF00D, incident
    /// EFB2E09B: app CPU ~1%, main thread parked in
    /// `__NSXPCCONNECTION_IS_WAITING_FOR_A_SYNCHRONOUS_REPLY__` under
    /// `-[AVAudioSession privateSetActive:withOptions:error:core:]`, reached from
    /// a Combine sink delivered on the main queue).
    ///
    /// Serial, so the ordering guarantees the old main-thread-only code relied on
    /// (deactivate-then-activate, category-before-active) still hold. AVAudioSession
    /// is thread-safe; it was never the main thread that made these calls correct.
    private static let sessionQueue = DispatchQueue(label: "com.openminis.audiosession.apply")

    /// Number of profile switches enqueued on `sessionQueue` but not yet applied.
    /// Written from BOTH the main actor (enqueue) and the session queue
    /// (completion), so it lives outside the actor's isolation with its own lock
    /// — see `beginAndWait`. `nonisolated` on the lock too, otherwise the
    /// background completion block can't touch it.
    nonisolated(unsafe) private static var pendingApplies = 0
    nonisolated private static let pendingLock = NSLock()

    // nanoMuse: 成功状态在硬件队列内提交，不能由主线程的乐观状态替代。
    nonisolated(unsafe) private static var appliedIntent: Intent?
    nonisolated(unsafe) private static var lastApplyError: (any Error)?

    nonisolated private static func hasApplied(_ intent: Intent) -> Bool {
        pendingLock.withLock { appliedIntent == intent && lastApplyError == nil }
    }

    private func apply(reason: String, force: Bool = false) {
        // nanoMuse: 主线程只决定目标，阻塞的硬件调用全部在串行会话队列执行。
        guard let top = highest else {
            enqueueDeactivation(reason: reason)
            return
        }
        let (cat, mode, opts) = profile(for: top)
        let session = AVAudioSession.sharedInstance()
        let needsReconfig = Self.needsConfiguration(session, category: cat, mode: mode, options: opts)
        // nanoMuse: 队列尚有旧配置时，主线程读取的硬件属性不足以证明目标已应用。
        let hasPendingApply = Self.pendingLock.withLock { Self.pendingApplies > 0 }
        let needsActivate = !sessionActive
        guard force || needsReconfig || needsActivate || hasPendingApply || !Self.hasApplied(top) else { return }
        sessionActive = true
        let shouldUseSpeaker = isCallSpeaker
        let log = logger
        Self.pendingLock.withLock { Self.pendingApplies += 1 }
        let started = CFAbsoluteTimeGetCurrent()
        Self.sessionQueue.async {
            defer { Self.pendingLock.withLock { Self.pendingApplies -= 1 } }
            do {
                try Self.configureSession(session, intent: top, category: cat, mode: mode,
                                          options: opts, activate: needsActivate, speaker: shouldUseSpeaker)
                Self.recordResult(intent: top, error: nil)
                let ms = (CFAbsoluteTimeGetCurrent() - started) * 1000
                log.info("[VoiceInputDebug][AudioSession] \(reason) → \(top) (\(cat.rawValue)/\(mode.rawValue)) applied in \(String(format: "%.0f", ms))ms")
            } catch {
                // nanoMuse: 只有硬件配置真实成功才保留已应用意图。
                Self.recordResult(intent: nil, error: error)
                let ms = (CFAbsoluteTimeGetCurrent() - started) * 1000
                log.error("[VoiceInputDebug][AudioSession] \(reason) apply FAILED after \(String(format: "%.0f", ms))ms: \(error.localizedDescription)")
            }
        }
    }

    // nanoMuse: 失效的乐观标志不能跳过已经排队的激活所需的对应释放。
    private func enqueueDeactivation(reason: String) {
        let hasOutstandingSession = Self.pendingLock.withLock {
            Self.pendingApplies > 0 || Self.appliedIntent != nil
        }
        guard sessionActive || hasOutstandingSession else { return }
        sessionActive = false
        logger.info("[AudioSession] \(reason) → idle, deactivating (async)")
        Self.pendingLock.withLock { Self.pendingApplies += 1 }
        Self.sessionQueue.async {
            defer { Self.pendingLock.withLock { Self.pendingApplies -= 1 } }
            do {
                let session = AVAudioSession.sharedInstance()
                if session.category == .playAndRecord {
                    // nanoMuse: 路由重置失败也必须继续尝试释放系统会话。
                    try? session.overrideOutputAudioPort(.none)
                }
                try session.setActive(false, options: .notifyOthersOnDeactivation)
                Self.recordResult(intent: nil, error: nil)
            } catch { Self.recordResult(intent: nil, error: error) }
        }
    }

    // nanoMuse: 同时比较类别、模式和选项，避免后台保活的混音设置残留到通话。
    nonisolated private static func needsConfiguration(
        _ session: AVAudioSession, category: AVAudioSession.Category,
        mode: AVAudioSession.Mode, options: AVAudioSession.CategoryOptions
    ) -> Bool {
        session.category != category || session.mode != mode || session.categoryOptions != options
    }

    // nanoMuse: 必须在硬件队列内重新比较，不能依赖排队前读取的过期属性。
    nonisolated private static func configureSession(
        _ session: AVAudioSession, intent: Intent, category: AVAudioSession.Category,
        mode: AVAudioSession.Mode, options: AVAudioSession.CategoryOptions,
        activate: Bool, speaker: Bool
    ) throws {
        let mustReconfigure = needsConfiguration(session, category: category, mode: mode, options: options)
        let mustActivate = activate || mustReconfigure || !hasApplied(intent)
        if mustReconfigure { try session.setCategory(category, mode: mode, options: options) }
        if mustActivate { try session.setActive(true) }
        if intent == .call { try session.overrideOutputAudioPort(speaker ? .speaker : .none) }
    }

    // nanoMuse: 真实结果在锁内统一提交，异步等待只读取这个结果。
    nonisolated private static func recordResult(intent: Intent?, error: (any Error)?) {
        pendingLock.withLock {
            appliedIntent = intent
            lastApplyError = error
        }
    }

    // MARK: - Unified interruption handling (replaces per-subsystem observers)

    /// Set by subsystems so the coordinator can resume them after an interruption.
    var onInterruptionEnded: (() -> Void)?

    /// True while TTS was paused by us because external audio took priority
    /// (interruption or secondary-audio-silence hint). Guards the resume so we
    /// never resume playback the USER paused.
    private var pausedByExternalAudio = false

    private func registerInterruptionObserver() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleInterruption(_:)),
            name: AVAudioSession.interruptionNotification, object: nil)
        // [T-tts-pause-on-external-record] A third-party keyboard's dictation
        // (or any other app recording) runs its OWN audio session alongside our
        // .playback/.spokenAudio one — iOS does NOT post an
        // interruptionNotification for that coexistence, so TTS kept talking
        // and the keyboard transcribed our own speech. The system DOES post
        // silenceSecondaryAudioHintNotification (.begin) when higher-priority
        // audio (recording/call) should dominate: pause TTS there, resume on
        // .end.
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleSilenceSecondaryAudioHint(_:)),
            name: AVAudioSession.silenceSecondaryAudioHintNotification, object: nil)
        // [T-tts-pause-inapp-keyboard-dictation] A third-party keyboard's
        // dictation started FROM INSIDE our app shares this process's audio
        // context — iOS does NOT post a silence-secondary-audio hint for it (that
        // notification fires only when ANOTHER app takes over). But the keyboard's
        // record session still triggers a route change, and the authoritative
        // `secondaryAudioShouldBeSilencedHint` property flips true while it holds
        // the mic. Poll that property on every route change and pause/resume TTS
        // accordingly, so in-app dictation gets the same treatment as cross-app
        // recording. (Reason codes alone are unreliable — categoryChange /
        // routeConfigurationChange fire for many unrelated cases — so we trust the
        // property, not the reason.)
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleRouteChange(_:)),
            name: AVAudioSession.routeChangeNotification, object: nil)
    }

    @objc private func handleRouteChange(_ note: Notification) {
        let shouldSilence = AVAudioSession.sharedInstance().secondaryAudioShouldBeSilencedHint
        if shouldSilence {
            pauseTTSForExternalAudio(reason: "route-change(secondary-silence)")
        } else {
            resumeTTSAfterExternalAudio(reason: "route-change(secondary-clear)")
        }
    }

    /// Pause reply TTS because external audio (interruption / recording in
    /// another app) needs to dominate. `pause()` keeps the synthesis queue so
    /// playback can pick up where it left off — deliberately NOT stopAll().
    ///
    /// The intent flag `pausedByExternalAudio` is latched INDEPENDENTLY of the
    /// player's physical `isPaused`: an external recording frequently stops our
    /// AVAudioPlayer BEFORE the pause signal arrives, so at this point there may
    /// be no live player to physically pause — but we still must remember that
    /// WE own the pause, or the matching `.end` won't resume. `pause()` now
    /// latches `isPaused` even with no live player and gates `pumpPlayback`, so
    /// the queue can't sneak a unit out under the recorder.
    private func pauseTTSForExternalAudio(reason: String) {
        // Idempotent: repeated BEGIN signals (interruption + secondary-hint can
        // both fire) must not clear an already-recorded pause intent.
        guard !pausedByExternalAudio else { return }
        pausedByExternalAudio = true
        VoiceOutputPlayer.shared.pause()
        logger.info("[AudioSession] \(reason) → TTS paused (external audio)")
    }

    /// Resume reply TTS if (and only if) WE paused it for external audio.
    private func resumeTTSAfterExternalAudio(reason: String) {
        guard pausedByExternalAudio else { return }
        pausedByExternalAudio = false
        VoiceOutputPlayer.shared.resume()
        logger.info("[AudioSession] \(reason) → TTS resumed")
    }

    @objc private func handleInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            logger.info("[AudioSession] interruption began")
            sessionActive = false   // system deactivated us
            // nanoMuse: 系统中断使旧激活结果失效，下一次启动必须再次激活。
            Self.pendingLock.withLock { Self.appliedIntent = nil }
            // Previously we only flagged the session inactive; the TTS queue
            // kept "playing" into a dead session. Pause it so the queue
            // survives and can resume when the interruption ends.
            pauseTTSForExternalAudio(reason: "interruption-began")
        case .ended:
            logger.info("[AudioSession] interruption ended → re-asserting")
            apply(reason: "interruption-ended")
            resumeTTSAfterExternalAudio(reason: "interruption-ended")
            onInterruptionEnded?()
        @unknown default:
            break
        }
    }

    @objc private func handleSilenceSecondaryAudioHint(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionSilenceSecondaryAudioHintTypeKey] as? UInt,
              let type = AVAudioSession.SilenceSecondaryAudioHintType(rawValue: raw) else { return }
        switch type {
        case .begin:
            logger.info("[AudioSession] silence-secondary-audio hint BEGIN")
            pauseTTSForExternalAudio(reason: "secondary-audio-hint")
        case .end:
            logger.info("[AudioSession] silence-secondary-audio hint END")
            resumeTTSAfterExternalAudio(reason: "secondary-audio-hint-end")
        @unknown default:
            break
        }
    }
}
