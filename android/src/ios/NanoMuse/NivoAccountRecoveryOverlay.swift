import SwiftUI

/// 恢复未完成时不展示可能属于另一账户的内容，保留明确的错误和重试操作。
struct NivoAccountRecoveryOverlay: View {
    @ObservedObject private var account = NanoMuseAccountData.shared

    var body: some View {
        VStack(spacing: 18) {
            if let error = account.recoveryError {
                Image(systemName: "externaldrive.badge.exclamationmark").font(.largeTitle)
                Text(AppLocalized("Saved data could not be opened. The original file was preserved."))
                    .font(.headline).multilineTextAlignment(.center)
                Text(error).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button(AppLocalized("Retry")) { Task { await account.recoverAtLaunch() } }
                    .buttonStyle(.borderedProminent)
            } else {
                ProgressView()
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground).ignoresSafeArea())
        .accessibilityElement(children: .contain)
    }
}
