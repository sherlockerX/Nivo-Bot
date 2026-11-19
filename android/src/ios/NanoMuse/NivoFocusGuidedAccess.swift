import SwiftUI
import UIKit

/// 引导式访问只读取系统的实际状态，开始和结束均交给系统快捷键和凭据。
@MainActor
struct NivoFocusGuidedAccess: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var isActive = false
    @State private var isShowingInstructions = false

    var body: some View {
        Button { isShowingInstructions = true } label: {
            Image(systemName: isActive ? "lock.fill" : "lock.open")
                .frame(width: 44, height: 44)
        }
        .accessibilityLabel(AppLocalized("Guided Access"))
        .accessibilityValue(isActive ? AppLocalized("On") : AppLocalized("Off"))
        .onAppear(perform: refreshStatus)
        .nmOnChange(of: scenePhase) { phase in
            if phase == .active { refreshStatus() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIAccessibility.guidedAccessStatusDidChangeNotification)) { _ in
            refreshStatus()
        }
        .sheet(isPresented: $isShowingInstructions) {
            NavigationStack {
                Form {
                    Section {
                        Label(isActive ? AppLocalized("On") : AppLocalized("Off"),
                              systemImage: isActive ? "lock.fill" : "lock.open")
                    }
                    Section {
                        if !isActive {
                            Text(AppLocalized("In Settings, go to Accessibility, then Guided Access. Turn it on and set a passcode or enable biometrics."))
                            Text(AppLocalized("Return to the timer and triple-click the side, top, or Home button. Choose Guided Access if prompted."))
                        }
                        if #available(iOS 26, *) {
                            Text(AppLocalized("To exit, triple-click the same button, authenticate, then choose End."))
                        } else {
                            Text(AppLocalized("To exit, double-click the same button, authenticate, then choose End."))
                        }
                        Text(AppLocalized("Guided Access stays on until you end it in iOS, even when your focus timer finishes."))
                    }
                }
                .navigationTitle(AppLocalized("Guided Access"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(AppLocalized("Done")) { isShowingInstructions = false }
                    }
                }
            }
        }
    }

    private func refreshStatus() {
        isActive = UIAccessibility.isGuidedAccessEnabled
    }
}
