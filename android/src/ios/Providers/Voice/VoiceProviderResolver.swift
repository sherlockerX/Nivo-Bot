import Foundation
import UIKit
import SwiftUI

// MARK: - VoiceProviderResolver
//
// Resolves the voice INPUT/OUTPUT provider from the configured ModelGroup
// (voiceInputGroupId / voiceOutputGroupId, parallel to Default Primary/Sub).
// Walks the group's members, keeps only audio-capable voice models for the
// direction, and returns the first usable provider. Falls back to the offline
// System provider when nothing in the group is usable (or no group is set).

// nanoMuse: 输入与输出选择保存在本设备，重新启动后仍优先于分组，不写入同步配置。
/// 设备本地语音模型选择，nil表示继续采用已配置分组或System。
@MainActor
final class VoiceSelectionStore: ObservableObject {
    static let shared = VoiceSelectionStore()
    private static let INPUT_ENTRY_KEY = "voice.input.overrideEntryId"
    private static let OUTPUT_ENTRY_KEY = "voice.output.overrideEntryId"
    private let defaults: UserDefaults

    /// 语音转文字的模型标识，支持System的在线和离线变体。
    @Published var inputEntryId: String? {
        didSet {
            guard oldValue != inputEntryId else { return }
            persist(inputEntryId, key: Self.INPUT_ENTRY_KEY)
        }
    }
    /// 文字转语音的模型标识，保留具体System音色的复合标识。
    @Published var outputEntryId: String? {
        didSet {
            guard oldValue != outputEntryId else { return }
            persist(outputEntryId, key: Self.OUTPUT_ENTRY_KEY)
        }
    }

    /// 可注入独立的偏好域，测试时无需读写用户的真实语音选择。
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        inputEntryId = defaults.string(forKey: Self.INPUT_ENTRY_KEY)
        outputEntryId = defaults.string(forKey: Self.OUTPUT_ENTRY_KEY)
    }

    /// 清除覆盖时移除键，使下次启动恢复分组和System的既有回退路径。
    private func persist(_ entryId: String?, key: String) {
        if let entryId { defaults.set(entryId, forKey: key) }
        else { defaults.removeObject(forKey: key) }
    }
}

/// In-memory composer input-mode (voice vs text), shared across ALL chat
/// sessions — like an input method's current state. Switching to voice in one
/// session carries into the next; NOT persisted, so a cold start resets to text.
@MainActor
final class VoiceModePreference: ObservableObject {
    static let shared = VoiceModePreference()
    /// True = composer is in inline-voice mode; false = text mode.
    @Published var isVoiceActive = false
    /// Whether the inline voice panel is expanded (vs compact). In-memory, carried
    /// across sessions — the panel resumes whatever the user left it at. Reset to
    /// the default (expanded) only on cold start.
    @Published var expanded = true
    /// One-shot: set true when the user switches text→voice, so the panel opens
    /// expanded that one time, then resumes the remembered state afterwards.
    var enteredFromText = false
    /// True while the mic is actively capturing (VAD running). Reply TTS is
    /// SUPPRESSED while this is true — capture and playback are mutually exclusive
    /// (no echo, no AVAudioSession category fight). Set by VoiceInputViewModel
    /// around startVAD / stopListening.
    @Published var isCapturing = false
    private init() {}
}

/// The actions a chat VM exposes so the GLOBAL voice capsule (which has no
/// session vm) can drive whichever session is currently reading aloud. The active
/// controller registers itself with `VoiceOutputState` when it starts speaking.
@MainActor
protocol SpeechControlling: AnyObject {
    func toggleSpeechPause()
    func stopSpeech()
    func nextSpeechSpeed()
    func disableSpeech(resetSpeed: Bool)
}

/// GLOBAL read-replies (TTS output) state — a single source of truth shared
/// across ALL chat sessions and the home screen. Backed by persisted
/// `VoiceOutputPreferences`. It also MIRRORS the live read-aloud state
/// (reading / paused / speed) from the active session so the home-screen capsule
/// can render + control playback without owning a session vm.
@MainActor
final class VoiceOutputState: ObservableObject {
    static let shared = VoiceOutputState()

    @Published var isEnabled: Bool {
        didSet {
            guard oldValue != isEnabled else { return }
            VoiceLog.log("[VoiceOutputState] isEnabled \(oldValue) → \(isEnabled)")
            VoiceOutputPreferences.isEnabled = isEnabled
            if !isEnabled {
                // Off → stop whatever is currently being read aloud, app-wide,
                // AND drop any queued-but-unplayed items. Also clear temporary
                // mute (it's meaningless once fully off, and a fresh enable should
                // start un-muted).
                VoiceOutputPlayer.shared.stopAll()
                activeController?.stopSpeech()
                isMuted = false
            }
        }
    }

    /// TEMPORARY mute — distinct from `isEnabled`. Muting silences playback and
    /// suppresses NEW reply TTS, but read-replies stays ON and the capsule stays
    /// VISIBLE (so the user can un-mute). Toggled by the capsule speaker (expand
    /// tap / compact double-tap). Full close = `isEnabled = false` (capsule hides).
    @Published var isMuted: Bool {
        didSet {
            guard oldValue != isMuted else { return }
            VoiceLog.log("[VoiceOutputState] isMuted \(oldValue) → \(isMuted)")
            VoiceOutputPreferences.isMuted = isMuted
            if isMuted {
                VoiceOutputPlayer.shared.stopAll()
                activeController?.stopSpeech()
            }
        }
    }

    /// Effective gate for producing reply audio: enabled AND not muted.
    var canPlay: Bool { isEnabled && !isMuted }

    // Mirrored live state (pushed by the active controller).
    @Published var isReadingAloud = false
    @Published var speechPaused = false
    @Published var speechSpeed: Float = VoiceOutputPreferences.speedMultiplier

    /// The session currently reading aloud — global capsule actions forward here.
    weak var activeController: SpeechControlling?

    /// Called by a chat VM when it becomes the one reading aloud.
    func registerActive(_ controller: SpeechControlling) {
        activeController = controller
    }

    /// Push live state up from the active controller so the capsule reflects it.
    func syncState(reading: Bool, paused: Bool, speed: Float) {
        if isReadingAloud != reading { isReadingAloud = reading }
        if speechPaused != paused { speechPaused = paused }
        if speechSpeed != speed { speechSpeed = speed }
    }

    // MARK: Global capsule actions (forward to the active controller; fall back to
    // the cloud player when no session vm is active).
    func togglePause() {
        if let c = activeController { c.toggleSpeechPause() }
        else { VoiceOutputPlayer.shared.isPaused ? VoiceOutputPlayer.shared.resume()
                                                 : VoiceOutputPlayer.shared.pause() }
    }
    func stop() {
        VoiceLog.log("[VoiceOutputState] stop() (isEnabled stays \(isEnabled))")
        if let c = activeController { c.stopSpeech() }
        else { VoiceOutputPlayer.shared.stopAll() }
        isReadingAloud = false; speechPaused = false
    }
    func nextSpeed() {
        activeController?.nextSpeechSpeed()
    }
    func disable() {
        VoiceLog.log("[VoiceOutputState] disable() → isEnabled=false")
        activeController?.disableSpeech(resetSpeed: true)
        isEnabled = false
    }

    private init() {
        self.isEnabled = VoiceOutputPreferences.isEnabled
        self.isMuted = VoiceOutputPreferences.isMuted
        registerLiveActivityToggleObserver()
    }

    /// [T-ios-live-activity-audio-toggle] Observe the Darwin notification the
    /// Live Activity play/pause button posts (from the widget process) and
    /// pause/resume read-aloud here in the app process. Relocated here from
    /// GlobalAudioPlayer as part of the b0f3f884 root-cause fix: the toggle
    /// drives the TTS engine (VoiceOutputState), not the chat audio-attachment
    /// player. `VoiceOutputState` is a never-deallocated singleton, so an
    /// unretained observer token is safe.
    private func registerLiveActivityToggleObserver() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            center, observer,
            { _, _, _, _, _ in
                // Darwin callbacks are C function pointers (no captured context),
                // so hop back to the singleton on the main actor.
                Task { @MainActor in
                    VoiceOutputState.shared.handleLiveActivityToggle()
                }
            },
            AudioTogglePlaybackBridge.darwinNotificationName as CFString,
            nil, .deliverImmediately
        )
    }

    /// [T-ios-live-activity-audio-toggle] Pause/resume read-aloud in response to
    /// the Live Activity button, then immediately push the audio state to the
    /// Live Activity so the icon flips without waiting for the next periodic
    /// refresh. Routed via `togglePause()` → activeController (System TTS) or
    /// VoiceOutputPlayer (cloud), never `stop()`.
    func handleLiveActivityToggle() {
        VoiceLog.log("[VoiceOutputState] Live Activity toggle received — isReadingAloud=\(isReadingAloud) speechPaused=\(speechPaused)")
        guard isReadingAloud else { return }
        togglePause()
        // [T-live-activity-audio-toggle-latency] This exact source string is what
        // tells AgentLiveActivityManager the push came from a USER TAP and may skip
        // the 3s/5s throttle (so the speaker glyph flips immediately). Use the
        // shared constant — a typo here would silently reinstate the up-to-5s lag.
        BackgroundKeepAliveManager.shared.audioPlaybackStateChanged(
            source: AgentLiveActivityManager.userAudioToggleSource
        )
    }
}

/// Window-coordinate avoidance for the app-root speech capsule. Instead of
/// guessing fixed lift values, every protectable element (input bar, keyboard,
/// scroll-jump buttons, voice panel) REGISTERS its frame in window coordinates;
/// the capsule then computes the actual overlap and lifts only as much as needed
/// to clear the highest overlapping rect. No fixed offsets, no accumulation.
@MainActor
final class SpeechCapsulePlacement: ObservableObject {
    static let shared = SpeechCapsulePlacement()

    /// Protected frames in WINDOW coordinates, keyed by owner ("inputBar",
    /// "keyboard", "scrollButtons", …). The capsule must not overlap any of them.
    @Published private(set) var protectedRects: [String: CGRect] = [:]

    /// Per-key debounce tasks for frame updates during keyboard animation.
    private var debounceTasks: [String: Task<Void, Never>] = [:]

    /// Debounced setRect — coalesces rapid frame changes (e.g. during keyboard
    /// animation or voice panel height growth) into a single update after 200ms
    /// of stability. The longer window prevents interleaved inputBar/keyboard
    /// updates from each resetting the other's debounce, which caused the
    /// capsule to jitter during transitions.
    func setRectDebounced(_ key: String, _ rect: CGRect?) {
        debounceTasks[key]?.cancel()
        debounceTasks[key] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            self?.setRect(key, rect)
        }
    }

    /// True if `r` looks like a real on-screen frame (not a layout/animation
    /// transient). SwiftUI's `.global` frame briefly reports garbage during
    /// transitions — negative X, off-screen, or absurd sizes — which made the
    /// capsule lift jump wildly. We reject those.
    private func isSaneRect(_ r: CGRect) -> Bool {
        let s = UIScreen.main.bounds
        guard r.width > 0.5, r.height > 0.5 else { return false }
        guard r.minX >= -2, r.maxX <= s.width + 2 else { return false }   // within screen X
        guard r.maxY > 0, r.minY < s.height + 2 else { return false }     // intersects screen
        guard r.width <= s.width + 2, r.height <= s.height else { return false }
        return true
    }

    /// Register / update a protected region (window coords). nil/empty removes it.
    func setRect(_ key: String, _ rect: CGRect?) {
        if let r = rect, isSaneRect(r) {
            if protectedRects[key] != r {
                protectedRects[key] = r
                VoiceLog.log("[capsule-placement] setRect \(key) y=\(Int(r.minY))…\(Int(r.maxY)) x=\(Int(r.minX))…\(Int(r.maxX))")
            }
        } else if rect == nil, protectedRects[key] != nil {
            protectedRects[key] = nil
            VoiceLog.log("[capsule-placement] clearRect \(key)")
        } else if let r = rect {
            VoiceLog.log("[capsule-placement] REJECT \(key) y=\(Int(r.minY))…\(Int(r.maxY)) x=\(Int(r.minX))…\(Int(r.maxX)) (insane)")
        }
    }
    func clearRect(_ key: String) { setRect(key, nil) }

    /// How far UP the capsule must move from its resting window frame so it clears
    /// every protected rect it horizontally overlaps. `spacing` = gap to keep.
    /// 0 when there's no overlap → capsule stays at its default position.
    ///
    /// ITERATIVE: obstacles STACK (keyboard at the bottom, input bar directly
    /// above it). The old single-pass version computed each rect's need against
    /// the RESTING frame only and took the max — the resting capsule overlapped
    /// just the keyboard, so it lifted exactly past the keyboard top… and landed
    /// INSIDE the input bar band above it (device log: inputBar y365…546,
    /// keyboard y546…874, lift=290 → displayBottom=538, squarely on the send
    /// button). Each pass re-checks overlap at the LIFTED position and raises
    /// again, so a stack of obstacles is cleared obstacle by obstacle until the
    /// frame is free (bounded iterations — rect count is tiny).
    func requiredLift(forCapsule capsule: CGRect, spacing: CGFloat = 8) -> CGFloat {
        guard capsule.width > 0 else { return 0 }

        // ALL rects participate (the keyboard included): the capsule ignores the
        // keyboard safe area so it does NOT get pushed up by the system — it must
        // avoid the keyboard rect itself, or it gets covered.
        var lift: CGFloat = 0
        var lastHit = ""
        var passes = 0
        var lines: [String] = []
        for pass in 0..<8 {
            passes = pass + 1
            let lifted = capsule.offsetBy(dx: 0, dy: -lift)
            var needed: CGFloat = 0
            var hitKey = ""
            for (k, r) in protectedRects {
                let xOverlap = r.maxX > lifted.minX && r.minX < lifted.maxX
                let yAmount = min(lifted.maxY, r.maxY) - max(lifted.minY, r.minY)
                let overlaps = xOverlap && yAmount > 4
                let n = overlaps ? max(0, lifted.maxY - (r.minY - spacing)) : 0
                if pass == 0 || overlaps {
                    lines.append("    p\(pass) \(k)[y\(Int(r.minY))…\(Int(r.maxY)) x\(Int(r.minX))…\(Int(r.maxX))] xOv=\(xOverlap) yOv=\(Int(yAmount)) overlap=\(overlaps) needLift=\(Int(n))")
                }
                if overlaps, n > needed { needed = n; hitKey = k }
            }
            guard needed > 0.5 else { break }
            lift += needed
            lastHit = hitKey
        }
        VoiceLog.log("[capsule-calc] capsule[y\(Int(capsule.minY))…\(Int(capsule.maxY)) x\(Int(capsule.minX))…\(Int(capsule.maxX))] rects=\(protectedRects.count) passes=\(passes) → lift=\(Int(lift)) by=\(lastHit.isEmpty ? "none" : lastHit)\n" + (lines.isEmpty ? "    (no protected rects)" : lines.joined(separator: "\n")))
        return lift
    }

    private init() {
        let nc = NotificationCenter.default
        let onKB: @Sendable (Notification) -> Void = { [weak self] note in
            let end = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect) ?? .zero
            Task { @MainActor in
                let screenH = UIScreen.main.bounds.height
                let visible = end.minY < screenH - 1 && end.height > 1
                // DEBOUNCED: the keyboard fires willChangeFrame many times during its
                // show/hide animation with intermediate frames (e.g. 318…874 then
                // 546…874). Applying each one made the capsule drift. Coalesce to the
                // last stable frame so avoidance only reacts to the settled keyboard.
                self?.setRectDebounced("keyboard", visible ? end : nil)
            }
        }
        nc.addObserver(forName: UIResponder.keyboardWillShowNotification, object: nil, queue: .main, using: onKB)
        nc.addObserver(forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main, using: onKB)
        nc.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main) { [weak self] _ in
            VoiceLog.log("[capsule-kbd] willHide → clear")
            Task { @MainActor in self?.setRectDebounced("keyboard", nil) }
        }
    }
}

/// Reports a view's window-coordinate frame to `SpeechCapsulePlacement` under a
/// key, keeping it updated as layout changes and clearing it on disappear.
struct CapsuleProtectedFrame: ViewModifier {
    let key: String
    private static func isSane(_ f: CGRect) -> Bool {
        let s = UIScreen.main.bounds
        return f.width > 0.5 && f.height > 0.5
            && f.minX >= -2 && f.maxX <= s.width + 2
            && f.maxY > 0 && f.minY < s.height + 2
    }
    func body(content: Content) -> some View {
        content
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear {
                            let f = geo.frame(in: .global)
                            if Self.isSane(f) { SpeechCapsulePlacement.shared.setRectDebounced(key, f) }
                        }
                        .onChange(of: geo.frame(in: .global)) { f in
                            if Self.isSane(f) { SpeechCapsulePlacement.shared.setRectDebounced(key, f) }
                        }
                }
            )
            .onDisappear { SpeechCapsulePlacement.shared.setRectDebounced(key, nil) }
    }
}

extension View {
    /// Mark this view as a region the global speech capsule must not cover.
    func capsuleProtectedFrame(_ key: String) -> some View {
        modifier(CapsuleProtectedFrame(key: key))
    }
}

@MainActor
enum VoiceProviderResolver {

    private static let logger = AppLogger(category: "VoiceResolver")

    static let systemEntryId = SystemVoiceProvider.builtinProviderId

    // nanoMuse: 持久化选择和分组成员共用System复合标识识别。
    /// 判断标识是否属于手机自带的语音服务。
    static func isSystemEntry(_ entryId: String?) -> Bool {
        guard let eid = entryId else { return false }
        return eid == systemEntryId || eid.hasPrefix(systemEntryId + "/")
    }

    /// The AVSpeechSynthesisVoice identifier the user picked for System TTS, if a
    /// SPECIFIC voice was chosen (composite id "<sentinel>/<voice.identifier>").
    /// Returns nil for the bare sentinel or legacy "…/system-tts" default, so the
    /// caller keeps its by-language auto-selection (no regression). The suffix is
    /// a real voice id only when it looks like one (contains a dot).
    static func selectedSystemVoiceId(_ entryId: String?) -> String? {
        guard let eid = entryId, eid.hasPrefix(systemEntryId + "/") else { return nil }
        let suffix = String(eid.dropFirst(systemEntryId.count + 1))
        return suffix.contains(".") ? suffix : nil
    }

    // nanoMuse: 具体System音色只取当前有效选择，显式自动音色不再被分组音色覆盖。
    /// 当前有效选择的System音色标识，nil表示按语言自动选取。
    static func resolvedSystemOutputVoiceId() -> String? {
        if let selected = effectiveOverrideEntryId(direction: .output) {
            return selectedSystemVoiceId(selected)
        }
        return selectedSystemVoiceId(resolveEntry(
            groupId: ProviderConfigStore.shared.voiceOutputGroupId, direction: .output
        )?.id)
    }

    /// Which System ASR variant the user selected. Offline = on-device (privacy,
    /// no limits, language switch matters); Online = server/cloud (accuracy, more
    /// languages). `.auto` = no explicit choice → provider prefers on-device when
    /// available.
    enum SystemInputMode { case auto, online, offline }

    // nanoMuse: 无效覆盖和被跳过的分组成员不再影响实际System识别模式。
    /// 当前有效System选择的识别模式，没有明确变体时采用自动选择。
    static func resolvedSystemInputMode() -> SystemInputMode {
        func mode(_ id: String?) -> SystemInputMode {
            guard let id else { return .auto }
            if id.hasSuffix("/system-asr-online")  { return .online }
            if id.hasSuffix("/system-asr-offline") { return .offline }
            return .auto
        }
        if let selected = effectiveOverrideEntryId(direction: .input) {
            return mode(selected)
        }
        return mode(resolveEntry(
            groupId: ProviderConfigStore.shared.voiceInputGroupId, direction: .input
        )?.id)
    }

    // nanoMuse: 页面、语音输入与朗读共用同一套持久化覆盖和分组回退规则。
    /// 有效的语音转文字模型，明确选择System时由调用方使用系统引擎。
    static func resolvedInputEntry() -> ModelEntry? {
        resolvedEntry(direction: .input)
    }

    // nanoMuse: 与输入侧一致，失效的本地选择回退到分组或System。
    /// 有效的文字转语音模型，明确选择System时由调用方使用系统引擎。
    static func resolvedOutputEntry() -> ModelEntry? {
        resolvedEntry(direction: .output)
    }

    /// Display name of the currently-resolved ASR engine (for UI). `includeInstance`
    /// false → just the model name (used where the group name is already shown, so
    /// the chip reads "Group · Model" instead of "Group · Model · Instance").
    static func inputModelLabel(includeInstance: Bool = true) -> String {
        label(for: resolvedInputEntry(), includeInstance: includeInstance)
    }

    /// Display name of the currently-resolved TTS engine (for UI).
    static func outputModelLabel(includeInstance: Bool = true) -> String {
        label(for: resolvedOutputEntry(), includeInstance: includeInstance)
    }

    /// Name of the group the resolved ASR entry belongs to (the configured voice
    /// input group), or nil when the offline System / a bare override is in use.
    static func inputGroupName() -> String? {
        let store = ProviderConfigStore.shared
        // nanoMuse: 本地选择已失效时，芯片也显示实际生效的回退分组。
        let sel = effectiveOverrideEntryId(direction: .input)
        // Show the group name when: (1) no override (following the group), or
        // (2) the override is a member of the configured group (picked a specific
        // model within it). Don't show when the override is the System sentinel or
        // a model from a different provider.
        guard let gid = store.voiceInputGroupId,
              let g = store.group(for: gid) else { return nil }
        if sel == nil || sel == systemEntryId { return sel == nil ? g.name : nil }
        if g.memberEntryIds.contains(sel!) { return g.name }
        return nil
    }

    /// Resolve the voice INPUT (ASR) provider; offline System fallback.
    static func inputProvider() -> any VoiceInputCapable {
        provider(for: resolvedInputEntry(), capable: { $0.supportsVoiceInput }) ?? SystemVoiceProvider.shared
    }

    /// Resolve the voice OUTPUT (TTS) provider; offline System fallback.
    static func outputProvider() -> any VoiceOutputCapable {
        provider(for: resolvedOutputEntry(), capable: { $0.supportsVoiceOutput }) ?? SystemVoiceProvider.shared
    }

    // MARK: - Resolution

    // nanoMuse: 只有该方向可用的覆盖才参与选择状态和System变体解析。
    /// 规范化后的有效本地覆盖标识，不可用时返回nil以继续采用分组。
    static func effectiveOverrideEntryId(direction: VoiceDirection) -> String? {
        let selected = direction == .input
            ? VoiceSelectionStore.shared.inputEntryId
            : VoiceSelectionStore.shared.outputEntryId
        guard let selected,
              let entry = usableEntry(selected, direction: direction) else { return nil }
        return isSystemEntry(selected) ? selected : entry.id
    }

    // nanoMuse: 保存System前缀的无效或反方向标识不能绕过分组回退。
    /// 校验System复合标识的方向，保留旧标识和具体已下载或未下载的系统音色。
    static func isUsableSystemEntryId(_ entryId: String, direction: VoiceDirection) -> Bool {
        guard isSystemEntry(entryId) else { return false }
        if entryId == systemEntryId { return true }
        let suffix = String(entryId.dropFirst(systemEntryId.count + 1))
        switch direction {
        case .input:
            return ["system-asr", "system-asr-online", "system-asr-offline", "input"].contains(suffix)
        case .output:
            return suffix == "system-tts" || suffix == "output" || suffix.contains(".")
        }
    }

    // nanoMuse: 失效覆盖不阻断分组，分组所有成员均失效时返回nil交给System。
    /// 返回该方向实际生效的模型，显式System覆盖继续保留原有nil语义。
    private static func resolvedEntry(direction: VoiceDirection) -> ModelEntry? {
        let store = ProviderConfigStore.shared
        let selected = effectiveOverrideEntryId(direction: direction)
        if isSystemEntry(selected) { return nil }
        let groupId = direction == .input ? store.voiceInputGroupId : store.voiceOutputGroupId
        let memberIds = groupId.flatMap { store.group(for: $0)?.memberEntryIds } ?? []
        guard let entryId = NanoMuseVoiceModels.preferredEntryId(
            overrideEntryId: selected,
            groupMemberEntryIds: memberIds,
            canUse: { usableEntry($0, direction: direction) != nil }
        ) else { return nil }
        return usableEntry(entryId, direction: direction)
    }

    private static func voiceCredentialOK(_ instance: ProviderInstance) -> Bool {
        // The built-in System engine needs no credential (offline / on-device), so
        // it's always usable; cloud instances need a stored credential.
        if instance.id == SystemVoiceProvider.builtinProviderId { return true }
        return instance.hasAnyCredential
    }

    // nanoMuse: 统一过滤已隐藏模型、禁用实例、缺少凭证及不支持该方向的提供方。
    /// 校验直接选择和分组成员，System虚拟模型无需凭证且允许隐藏标记。
    static func usableEntry(_ entryId: String?, direction: VoiceDirection) -> ModelEntry? {
        let store = ProviderConfigStore.shared
        guard let entryId else { return nil }
        if isSystemEntry(entryId) {
            guard isUsableSystemEntryId(entryId, direction: direction) else { return nil }
            if entryId == systemEntryId { return direction == .input ? .systemASR : .systemTTS }
        }
        guard let entry = store.entry(for: entryId),
              !entry.isHidden || isSystemEntry(entry.providerInstanceId),
              canServe(entry.model, direction: direction),
              let instance = store.instance(for: entry.providerInstanceId),
              instance.isEnabled, voiceCredentialOK(instance),
              let provider = VoiceProviderFactory.make(for: instance) else { return nil }
        let canServeDirection = direction == .input ? provider.supportsVoiceInput : provider.supportsVoiceOutput
        guard canServeDirection else { return nil }
        return entry
    }

    /// Whether `model` can serve `direction`: dedicated voice model OR multimodal
    /// with the required audio modality.
    private static func canServe(_ model: LLMModel, direction: VoiceDirection) -> Bool {
        if direction.isVoiceModel(model) { return true }
        let m = model.capabilities.supportedModalities
        switch direction {
        case .input:  return m.contains(.audioInput)
        case .output: return m.contains(.audioOutput)
        }
    }

    /// The first audio-capable member of `groupId` whose instance is usable for
    /// `direction`. Returns nil → caller uses the offline System provider.
    private static func resolveEntry(groupId: String?, direction: VoiceDirection) -> ModelEntry? {
        resolveEntries(groupId: groupId, direction: direction).first
    }

    /// ALL audio-capable, usable members of `groupId` for `direction`, in group
    /// order. Used for fail-over (try the next model when one errors).
    private static func resolveEntries(groupId: String?, direction: VoiceDirection) -> [ModelEntry] {
        let store = ProviderConfigStore.shared
        guard let groupId, let group = store.group(for: groupId) else { return [] }
        // nanoMuse: 分组与直接选择共用可用性判断，避免页面显示和运行时回退分歧。
        return group.memberEntryIds.compactMap { usableEntry($0, direction: direction) }
    }

    // nanoMuse: 候选顺序读取有效的持久化覆盖，失效覆盖继续跟随分组。
    /// 语音输入候选先采用有效的本地覆盖，再采用分组顺序或负载均衡顺序。
    /// 明确选择System时返回空数组，由调用方直接采用系统引擎。
    static func resolvedInputCandidates(loadBalanceSeed: Int = 0) -> [ModelEntry] {
        let sel = effectiveOverrideEntryId(direction: .input)
        if isSystemEntry(sel) { return [] }
        var out: [ModelEntry] = []
        if let override = usableEntry(sel, direction: .input) {
            out.append(override)
        }
        let store = ProviderConfigStore.shared
        var members = resolveEntries(groupId: store.voiceInputGroupId, direction: .input)
        if let gid = store.voiceInputGroupId, let g = store.group(for: gid),
           g.strategy == .loadBalance, members.count > 1 {
            let offset = abs(loadBalanceSeed) % members.count
            members = Array(members[offset...] + members[..<offset])
        }
        for e in members where !out.contains(where: { $0.id == e.id }) {
            out.append(e)
        }
        return out
    }

    /// Build the ASR provider for a specific candidate entry (nil if not usable).
    static func inputProvider(for entry: ModelEntry) -> (any VoiceInputCapable)? {
        guard let instance = ProviderConfigStore.shared.instance(for: entry.providerInstanceId),
              let p = VoiceProviderFactory.make(for: instance), p.supportsVoiceInput else { return nil }
        return p
    }

    // nanoMuse: 明确选择System时不再把云端分组成员加入朗读候选。
    /// System覆盖只保留系统候选，使已进入朗读队列的段落也能继续播放。
    static func resolvedOutputCandidates() -> [ModelEntry] {
        let selected = effectiveOverrideEntryId(direction: .output)
        if isSystemEntry(selected), let system = usableEntry(selected, direction: .output) {
            return [system]
        }
        var out: [ModelEntry] = []
        if let override = usableEntry(selected, direction: .output) {
            out.append(override)
        }
        for e in resolveEntries(groupId: ProviderConfigStore.shared.voiceOutputGroupId, direction: .output)
        where !out.contains(where: { $0.id == e.id }) {
            out.append(e)
        }
        return out
    }

    /// Build the cloud TTS provider for a specific entry (nil if not usable / System).
    static func outputProvider(for entry: ModelEntry) -> (any VoiceOutputCapable)? {
        guard let instance = ProviderConfigStore.shared.instance(for: entry.providerInstanceId),
              let p = VoiceProviderFactory.make(for: instance), p.supportsVoiceOutput else { return nil }
        return p
    }

    private static func provider(for entry: ModelEntry?,
                                 capable: (any VoiceProviderCapable) -> Bool) -> (any VoiceProviderCapable)? {
        guard let entry,
              let instance = ProviderConfigStore.shared.instance(for: entry.providerInstanceId),
              let p = VoiceProviderFactory.make(for: instance), capable(p) else { return nil }
        logger.info("Resolved voice provider from entry \(entry.id)")
        return p
    }

    private static func label(for entry: ModelEntry?, includeInstance: Bool = true) -> String {
        guard let entry else {
            return AppLocalized("System", comment: "Built-in Apple speech engine")
        }
        // Only append the instance label when asked AND it isn't the built-in
        // System engine (whose synthetic "System" instance just duplicates the
        // model's built-in-ness — noise on the chip).
        if includeInstance,
           !isSystemEntry(entry.providerInstanceId),
           let inst = ProviderConfigStore.shared.instance(for: entry.providerInstanceId) {
            return "\(entry.model.displayName) · \(inst.label)"
        }
        return entry.model.displayName
    }
}
