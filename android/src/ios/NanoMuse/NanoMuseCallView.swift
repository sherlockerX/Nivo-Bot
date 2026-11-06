import SwiftUI

/// 全屏通话入口，设置可在开始前编辑，离开页面立即释放麦克风。
@MainActor
struct NanoMuseCallView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var call: NanoMuseCallSession
    @State private var settings = NanoMuseCallSettings.load()
    @State private var isShowingSettings = false

    /// 通话复用传入的聊天，不新建隐形对话。
    init(vm: AIChatViewModel) {
        _call = StateObject(wrappedValue: NanoMuseCallSession(vm: vm))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer(minLength: 12)
                NanoMuseFaceView(mood: call.phase == .thinking ? .working : .idle, size: 140)
                    .accessibilityHidden(true)
                Text(AppLocalized(String.LocalizationValue(stringLiteral: call.phase.rawValue))).font(.title2)
                if call.isMuted { Text(AppLocalized("Microphone muted")).foregroundStyle(.secondary) }
                transcript
                if let problem = call.problem {
                    Text(problem).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                }
                Spacer(minLength: 12)
                controls
            }
            .padding(24)
            .navigationTitle(AppLocalized("Voice call"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(AppLocalized("Close")) { call.hangUp(); dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { isShowingSettings = true } label: {
                        Image(systemName: "gearshape").accessibilityLabel(AppLocalized("Call settings"))
                    }.disabled(call.isRunning)
                }
            }
            .sheet(isPresented: $isShowingSettings) { NanoMuseCallSettingsView(settings: $settings) }
            .onDisappear { call.hangUp() }
            .nmOnChange(of: scenePhase) { phase in
                // 本批次只提供前台通话，切入后台立即释放录音。
                if phase == .background { call.hangUp() }
            }
        }
    }

    private var transcript: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !call.heard.isEmpty {
                    Text(call.heard).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                }
                if !call.reply.isEmpty {
                    Text(call.reply).frame(maxWidth: .infinity, alignment: .leading)
                }
            }.textSelection(.enabled)
        }.frame(maxHeight: 260)
    }

    @ViewBuilder private var controls: some View {
        if call.isRunning {
            HStack(spacing: 30) {
                Button { call.toggleMute() } label: {
                    Label(AppLocalized(call.isMuted ? "Unmute" : "Mute"), systemImage: call.isMuted ? "mic.slash" : "mic")
                }
                Button { call.toggleSpeaker() } label: {
                    Label(AppLocalized(call.isSpeaker ? "Use earpiece" : "Use speaker"), systemImage: call.isSpeaker ? "speaker.wave.2" : "ear")
                }
            }.buttonStyle(.bordered).disabled(!call.isAudioReady)
            Button(AppLocalized("Interrupt")) { call.interrupt() }
                .disabled(call.phase != .thinking && call.phase != .speaking)
            Button(role: .destructive) { call.hangUp() } label: {
                Label(AppLocalized("Hang up"), systemImage: "phone.down.fill").frame(maxWidth: .infinity)
            }.buttonStyle(.borderedProminent)
        } else {
            Button { Task { await call.start(settings: settings) } } label: {
                Label(AppLocalized("Start call"), systemImage: "phone.fill").frame(maxWidth: .infinity)
            }.buttonStyle(.borderedProminent)
            Text(AppLocalized("Keep this page in the foreground during the call."))
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
}

/// 通话使用独立语音模型，区域和凭证始终绑定到同一服务商。
@MainActor
private struct NanoMuseCallSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var settings: NanoMuseCallSettings

    var body: some View {
        NavigationStack {
            Form {
                Section(AppLocalized("Model Studio provider")) {
                    Picker(AppLocalized("Provider"), selection: $settings.providerId) {
                        Text(AppLocalized("First enabled Model Studio provider")).tag("")
                        ForEach(NanoMuseCallSettings.providers) { provider in
                            Text(provider.label).tag(provider.id)
                        }
                    }
                    field("WebSocket address (optional)", text: $settings.endpoint)
                    Text(AppLocalized("Leave the address empty to use the selected provider's region."))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section(AppLocalized("Speech models")) {
                    field("Speech recognition model", text: $settings.asrModel)
                    field("Speech synthesis model", text: $settings.ttsModel)
                    field("Voice", text: $settings.voice)
                    Stepper(value: $settings.silenceMs, in: 200...6000, step: 100) {
                        Text(String(format: AppLocalized("Pause that ends your turn: %d ms"), settings.silenceMs))
                    }
                    Text(AppLocalized("CosyVoice v3.5 needs a cloned or designed voice. Use a voice that matches your model."))
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle(AppLocalized("Call settings"))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(AppLocalized("Done")) { settings.save(); dismiss() }
                }
            }
            .onDisappear { settings.save() }
        }
    }

    private func field(_ title: String, text: Binding<String>) -> some View {
        TextField(AppLocalized(String.LocalizationValue(stringLiteral: title)), text: text)
            .textInputAutocapitalization(.never).autocorrectionDisabled()
    }
}

/// 将全屏通话放在独立修饰器内，保持主聊天视图的泛型链深度。
@MainActor
struct NanoMuseCallHost: ViewModifier {
    let vm: AIChatViewModel
    let readOnly: Bool
    let voice: VoiceInputViewModel
    @State private var isPresented = false

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .nanoMuseChatAction)) { note in
                guard !readOnly, NanoMuseChatAction.from(note, for: vm.nmSessionKey) == .voiceCall else { return }
                voice.stopListening()
                isPresented = true
            }
            .fullScreenCover(isPresented: $isPresented) { NanoMuseCallView(vm: vm) }
    }
}
