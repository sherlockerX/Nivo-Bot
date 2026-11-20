import SwiftUI

/// 无可用会话模型时给出原地配置入口，不遮挡本地页面或清空聊天草稿。
struct NivoModelSetupNotice: View {
    var canChooseModel: Bool
    var onAddProvider: () -> Void
    var onChooseModel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(AppLocalized("No model configured. Add a provider in Settings."))
                .font(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 16) {
                Button(AppLocalized("Add Provider"), action: onAddProvider)
                if canChooseModel { Button(AppLocalized("Choose Model"), action: onChooseModel) }
            }
            .font(.footnote.weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(NanoMuseTones.fill, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}
