import SwiftUI

/// 全屏计时保留到用户主动离开；锁屏恢复读取真实会话，不依赖后台持续刷新。
struct NivoFocusImmersiveView: View {
    var sessionID: String
    @ObservedObject var model: NivoLifeModel
    var backgroundID: String
    let access: NivoLifeScope
    var onReflection: () -> Void
    var onFollowUp: (NivoFocusSession) -> Void
    var onClose: () -> Void
    @Environment(\.scenePhase) private var scenePhase
    @State private var keepAwake = false
    @State private var isConfirmingFinish = false
    @State private var previousIdleSetting = false
    @State private var isOpeningReflection = false
    @State private var isStartingFollowUp = false

    private var session: NivoFocusSession? {
        guard model.accessScope == access else { return nil }
        return model.focusSessions.first { $0.id == sessionID && $0.ownerKey == access.ownerKey }
    }

    var body: some View {
        ZStack {
            NivoFocusBackdropView(backgroundID: backgroundID, ownerKey: access.ownerKey).ignoresSafeArea()
            Color.black.opacity(0.22).ignoresSafeArea()
            LinearGradient(colors: [.black.opacity(0.45), .clear, .black.opacity(0.65)],
                           startPoint: .top, endPoint: .bottom).ignoresSafeArea()
            if let session {
                GeometryReader { geometry in
                    ScrollView {
                        content(session).frame(minHeight: geometry.size.height)
                            .frame(maxWidth: .infinity)
                    }
                }
            } else {
                VStack(spacing: 20) {
                    Text(AppLocalized("This session is no longer available."))
                    Button(AppLocalized("Close"), action: onClose).buttonStyle(.bordered)
                }.padding(24)
            }
        }
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .statusBarHidden()
        .interactiveDismissDisabled()
        .onAppear {
            previousIdleSetting = UIApplication.shared.isIdleTimerDisabled
            keepAwake = NivoFocusPreferences.keepAwake(owner: access.ownerKey)
            updateIdleTimer()
        }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = previousIdleSetting }
        .nmOnChange(of: keepAwake) { value in
            if model.accessScope == access { NivoFocusPreferences.setKeepAwake(value, owner: access.ownerKey) }
            updateIdleTimer()
        }
        .nmOnChange(of: scenePhase) { phase in
            updateIdleTimer()
            if phase == .active { Task { await model.refresh() } }
        }
        .nmOnChange(of: session?.status) { _ in updateIdleTimer() }
        .modifier(NivoFocusRefresh(model: model, isVisible: model.accessScope == access))
        .confirmationDialog(AppLocalized("Finish this session?"), isPresented: $isConfirmingFinish, titleVisibility: .visible) {
            if let session {
                Button(AppLocalized("Finish focus")) { Task { _ = await model.controlFocus(session, action: "finish", scope: access) } }
            }
        } message: { Text(AppLocalized("Only the time actually focused will be recorded.")) }
        .alert(AppLocalized("Error"), isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button(AppLocalized("Close")) { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }

    private func content(_ session: NivoFocusSession) -> some View {
        VStack(spacing: 22) {
            HStack {
                Button(action: onClose) { Image(systemName: "chevron.down").frame(width: 44, height: 44) }
                    .accessibilityLabel(AppLocalized(session.isActive ? "Keep running in background" : "Close"))
                    .disabled(isOpeningReflection || isStartingFollowUp)
                Spacer()
                NivoFocusGuidedAccess()
                Toggle(isOn: $keepAwake) { Image(systemName: keepAwake ? "sun.max.fill" : "sun.max") }
                    .toggleStyle(.button).accessibilityLabel(AppLocalized("Keep screen awake"))
            }
            Spacer(minLength: 12)
            VStack(spacing: 18) {
                Text(session.title).font(.title2.weight(.medium)).multilineTextAlignment(.center).lineLimit(4)
                Text(session.mode.title + " · " + session.status.title).font(.subheadline)
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    let display = NivoFocusPresentationRules.displayedDuration(session, clock: NivoLifeClock.sample())
                    Text(NivoFocusFormat.clock(display))
                        .font(.system(size: 82, weight: .light, design: .rounded)).monospacedDigit()
                        .minimumScaleFactor(0.45).lineLimit(1)
                        .accessibilityLabel(AppLocalized(session.status == .finished ? "Focused time" : "Timer") + " " + NivoFocusFormat.clock(display))
                }
                if session.status == .finished {
                    Text(AppLocalized("Your focused time has been saved.")).font(.subheadline)
                }
            }.shadow(color: .black.opacity(0.5), radius: 10, y: 2)
            Spacer(minLength: 16)
            controls(session)
        }.padding(.horizontal, 28).padding(.vertical, 20).frame(maxWidth: 680)
    }

    @ViewBuilder private func controls(_ session: NivoFocusSession) -> some View {
        if session.status == .finished {
            if model.activeFocus == nil,
               let next = NivoFocusPresentationRules.followUp(after: session, sessions: model.focusSessions) {
                Button { Task { await startFollowUp(after: session) } } label: {
                    if next.mode == .rest {
                        let minutes = String(format: AppLocalized("%lld min"), Int64(next.minutes))
                        Label(AppLocalized("Start break") + " · " + minutes, systemImage: "cup.and.saucer")
                    } else {
                        Label(AppLocalized("Continue focusing"), systemImage: "play.fill")
                    }
                }.buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(isStartingFollowUp || isOpeningReflection || model.isBusy)
            }
            if NivoFocusReflectionRules.canReflect(session) {
                Text(AppLocalized("Reflect on this session. Its focus time and linked task are included automatically."))
                    .font(.subheadline).multilineTextAlignment(.center).frame(maxWidth: 360)
                Button {
                    guard !isStartingFollowUp, !isOpeningReflection, model.accessScope == access, model.isMosaicReady else { return }
                    isOpeningReflection = true
                    onReflection()
                } label: {
                    Label(AppLocalized("Record reflection"), systemImage: "square.and.pencil")
                }.buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(isStartingFollowUp || isOpeningReflection || model.isBusy || !model.isMosaicReady
                              || model.accessScope != access)
            }
            Button(AppLocalized("Done"), action: onClose).buttonStyle(.bordered).controlSize(.large)
                .disabled(isOpeningReflection || isStartingFollowUp)
        } else {
            HStack(spacing: 16) {
                Button { Task { _ = await model.controlFocus(session, action: session.status == .paused ? "resume" : "pause", scope: access) } } label: {
                    Label(AppLocalized(session.status == .paused ? "Resume" : "Pause"),
                          systemImage: session.status == .paused ? "play.fill" : "pause.fill")
                        .frame(maxWidth: .infinity).padding(.vertical, 10)
                }.buttonStyle(.borderedProminent).tint(.white.opacity(0.2))
                Button { isConfirmingFinish = true } label: {
                    Label(AppLocalized("Finish"), systemImage: "stop.fill").frame(maxWidth: .infinity).padding(.vertical, 10)
                }.buttonStyle(.bordered).tint(.white)
            }.disabled(model.isBusy || model.accessScope != access)
        }
    }

    private func startFollowUp(after source: NivoFocusSession) async {
        guard !isStartingFollowUp, !isOpeningReflection, model.accessScope == access else { return }
        isStartingFollowUp = true
        defer { isStartingFollowUp = false }
        guard let next = await model.startFocusFollowUp(after: source, scope: access), model.accessScope == access else { return }
        NivoFocusPreferences.bindBackground(backgroundID, sessionID: next.id, owner: access.ownerKey)
        onFollowUp(next)
        await NivoFocusNotifications.shared.requestPermission()
    }

    private func updateIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = scenePhase == .active && keepAwake
            && model.accessScope == access && session?.isActive == true
            ? true : previousIdleSetting
    }
}
