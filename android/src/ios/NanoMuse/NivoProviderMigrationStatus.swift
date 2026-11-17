import SwiftUI

/// 迁移失败保持局部可见状态，不阻断应用其他页面；所有窗口共享同一次操作。
@MainActor
final class NivoProviderMigrationStatus: ObservableObject {
    static let shared = NivoProviderMigrationStatus()
    @Published private(set) var isRunning = false
    @Published private(set) var messageKey: String?
    private var task: Task<Bool, Never>?

    /// 完整错误不包含秘密，界面按故障类别给出固定说明与重试入口。
    func run(store: ProviderConfigStore) async -> Bool {
        if let task { return await task.value }
        isRunning = true
        let operation = Task { @MainActor in
            do {
                try await NivoLegacyProviderMigration.run(store: store)
                self.messageKey = nil
                return true
            } catch {
                self.messageKey = error as? NivoOAuthPersistenceError == .conflictingCredential
                    ? "nivo.providers.migration.conflict" : "nivo.providers.migration.retry"
                AppLogger(category: "ProviderMigration").error("[Nivo] legacy provider migration remains pending")
                return false
            }
        }
        task = operation
        let succeeded = await operation.value
        task = nil
        isRunning = false
        return succeeded
    }
}

/// 两种设置布局共用相同的迁移进度与失败提示。
struct NivoProviderMigrationNotice: View {
    @ObservedObject private var status = NivoProviderMigrationStatus.shared

    var body: some View {
        if status.isRunning || status.messageKey != nil {
            VStack(alignment: .leading, spacing: 10) {
                if status.isRunning {
                    ProgressView(AppLocalized("nivo.providers.migration.running"))
                } else if let key = status.messageKey {
                    Label(AppLocalized(String.LocalizationValue(stringLiteral: key)), systemImage: "exclamationmark.triangle")
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(AppLocalized("Retry")) {
                        Task { await ProviderMigration.prepareModels(store: ProviderConfigStore.shared) }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(NanoMuseTones.surface, in: RoundedRectangle(cornerRadius: 16))
        }
    }
}

extension NivoOAuthPersistenceError: LocalizedError {
    /// 登录页沿用本地化错误，避免显示系统状态码或任何令牌内容。
    var errorDescription: String? { AppLocalized("nivo.providers.credential.save_failed") }
}
