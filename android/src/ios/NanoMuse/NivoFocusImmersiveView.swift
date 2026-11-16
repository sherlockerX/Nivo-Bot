import SwiftUI

/// 全屏计时保留到用户主动离开；锁屏恢复读取真实会话，不依赖后台持续刷新。
struct NivoFocusImmersiveView: View {
    var sessionID: String
    @ObservedObject var model: NivoLifeModel
    var backgroundID: String
    let access: NivoLifeScope
    var onClose: () -> Void
    @Environment(\.scenePhase) private var scenePhase
    @State private var keepAwake = false
    @State private var isConfirmingFinish = false
    @State private var previousIdleSetting = false

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
            if let session { content(session) }
            else {
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
                    .accessibilityLabel(AppLocalized("Keep running in background"))
                Spacer()
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
            Button(AppLocalized("Done"), action: onClose).buttonStyle(.borderedProminent).controlSize(.large)
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

    private func updateIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = scenePhase == .active && keepAwake
            && model.accessScope == access && session?.isActive == true
            ? true : previousIdleSetting
    }
}
