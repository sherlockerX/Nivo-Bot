import SwiftUI
import SafariServices

/// Minimal device-code login sheet for Kimi Code OAuth (RFC 8628). Presents the
/// user code + verification URL while `KimiOAuthManager` polls the token
/// endpoint in the background. Self-contained so the provider screens only need
/// to present it — mirrors the state/error surface of the other OAuth flows.
///
/// Usage (once ProviderType.kimiCode is wired):
///   .sheet(isPresented: $showKimiLogin) {
///       KimiDeviceLoginSheet(instanceId: instance.id) { success in ... }
///   }
@available(iOS 16.0, *)
struct KimiDeviceLoginSheet: View {
    let instanceId: String
    // nanoMuse: 详情页和新增页的来源随设备码表单传入，呈现等待不能跨账户。
    var sourceScope: NivoOAuthScope? = nil
    /// nanoMuse: 关闭时报告实际写入结果，成功提示期间取消也不能把已存凭证当作失败。
    var onFinish: (Bool) -> Void

    @Environment(\.dismiss) private var dismiss

    private enum Phase: Equatable {
        case starting
        case awaitingUser(userCode: String, url: String)
        case success
        case failed(String)
    }

    @State private var phase: Phase = .starting
    @State private var copied = false
    @State private var loginTask: Task<Void, Never>?
    // nanoMuse: 延时、取消按钮和系统关闭共享一次性完成状态。
    @State private var completion = NivoOAuthLoginCompletion()
    @State private var isClosing = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                switch phase {
                case .starting:
                    ProgressView()
                    Text(AppLocalized("Contacting Kimi…"))
                        .foregroundStyle(.secondary)

                case let .awaitingUser(userCode, url):
                    awaitingBody(userCode: userCode, url: url)

                case .success:
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(.green)
                    Text(AppLocalized("Signed in to Kimi Code"))
                        .font(.headline)

                case let .failed(message):
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(.orange)
                    Text(message)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                    Button(AppLocalized("Try Again")) { start() }
                        .buttonStyle(.borderedProminent)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
            .navigationTitle(AppLocalized("Kimi Code Login"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppLocalized("Cancel")) { finish() }
                }
            }
        }
        .interactiveDismissDisabled(phase == .starting)
        .onAppear { start() }
        // nanoMuse: 下拉关闭也回报实际写入状态，调用方才能接管未保存草稿。
        .onDisappear {
            settleCompletion()
        }
    }

    @ViewBuilder
    private func awaitingBody(userCode: String, url: String) -> some View {
        Text(AppLocalized("1. Open the verification page\n2. Enter this code to authorize nanoMuse"))
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)

        // The user code — tap to copy.
        Button {
            UIPasteboard.general.string = userCode
            copied = true
        } label: {
            HStack(spacing: 8) {
                Text(userCode)
                    .font(.system(.title, design: .monospaced).weight(.semibold))
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 20)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)

        Button {
            if let u = URL(string: url) { presentSafari(u) }
        } label: {
            Label(AppLocalized("Open verification page"), systemImage: "safari")
        }
        .buttonStyle(.borderedProminent)

        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text(AppLocalized("Waiting for authorization…"))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 4)
    }

    private func start() {
        // nanoMuse: 已完成的页面不重新发起登录或重置已写入状态。
        guard !isClosing, !completion.hasFinished, !completion.hasPersistedCredential else { return }
        loginTask?.cancel()
        copied = false
        phase = .starting
        loginTask = Task { @MainActor in
            do {
                if let sourceScope { try NivoOAuthAccess.validateScope(sourceScope) }
                try await KimiOAuthManager.shared.login(instanceId: instanceId) { presentation in
                    // nanoMuse: 管理器验证取消后直接回写，避免脱离登录任务的迟到UI更新。
                    guard !Task.isCancelled else { return }
                    phase = .awaitingUser(userCode: presentation.userCode,
                                          url: presentation.verificationURL)
                }
                // nanoMuse: 管理器返回即已确认写入，必须先记账再检查取消或等待提示。
                completion.didPersist()
                if Task.isCancelled { return }
                phase = .success
                // nanoMuse: 成功短暂提示后关闭；期间取消仍由结算回调报告实际写入结果。
                try await Task.sleep(nanoseconds: 900_000_000)
                try Task.checkCancellation()
                if let sourceScope { try NivoOAuthAccess.validateScope(sourceScope) }
                finish()
            } catch is CancellationError {
                // user cancelled — no error surface
            } catch {
                if Task.isCancelled { return }
                phase = .failed(error.localizedDescription)
            }
        }
    }

    // nanoMuse: 所有关闭路径只通知一次，成功后的取消保留成功结果。
    private func finish() {
        settleCompletion()
        dismiss()
    }

    // nanoMuse: 取消可能恰好发生在Keychain写入与await返回之间，必须等任务结算后报告。
    private func settleCompletion() {
        guard !isClosing else { return }
        isClosing = true
        let task = loginTask
        task?.cancel()
        Task { @MainActor in
            await task?.value
            reportCompletion()
        }
    }

    // nanoMuse: 生命周期关闭只回报结果，不再次调用dismiss。
    private func reportCompletion() {
        if let success = completion.finish() { onFinish(success) }
    }

    /// Open the verification page in an in-app SFSafariViewController — matching
    /// how the other OAuth providers (Claude / Codex / Gemini) present their auth
    /// pages, rather than jumping out to system Safari. Presented from the
    /// top-most VC (which is this sheet) so it stacks over the login sheet.
    private func presentSafari(_ url: URL) {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first,
              let root = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController else { return }
        var topVC = root
        while let presented = topVC.presentedViewController { topVC = presented }
        topVC.present(SFSafariViewController(url: url), animated: true)
    }
}
