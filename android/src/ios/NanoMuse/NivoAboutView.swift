import SwiftUI
import UIKit

/// 关于页保留本地版本、产品说明、隐私与许可证，不放仓库推广或在线更新入口。
struct NivoAboutView: View {
    private var installedLine: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
    private let buildDate: String? = {
        guard let file = Bundle.main.executableURL,
              let values = try? file.resourceValues(forKeys: [.contentModificationDateKey]),
              let date = values.contentModificationDate else { return nil }
        return date.formatted(date: .numeric, time: .standard)
    }()

    var body: some View {
        NanoMusePage(title: AppLocalized("About")) {
            VStack(spacing: 10) {
                if let icon = UIImage(named: "AppIcon60x60") ?? UIImage(named: "AppIcon") {
                    Image(uiImage: icon).resizable().frame(width: 72, height: 72)
                        .clipShape(RoundedRectangle(cornerRadius: 18)).accessibilityHidden(true)
                }
                Text(NivoProduct.name).font(.title2.bold())
                Text(installedLine).font(.subheadline).foregroundStyle(.secondary).textSelection(.enabled)
                if let buildDate {
                    Text(String(format: AppLocalized("Built %@"), buildDate))
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Text(AppLocalized("AI chat, tasks, focus, daily fragments and learning in one personal workspace."))
                    .font(.body).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 28).padding(.vertical, 20)

            NanoMuseCard {
                externalLink(AppLocalized("Project website"), NivoProduct.website)
                NanoMuseRowDivider()
                externalLink(AppLocalized("Model setup guide"), NivoProduct.modelGuide)
            }

            NanoMuseCard {
                externalLink(AppLocalized("Privacy policy"), NivoProduct.privacy)
                NanoMuseRowDivider()
                NanoMuseRowLabel(title: AppLocalized("License"), value: "GPL-3.0-or-later", chevron: false)
            }

            NanoMuseCaption(text: AppLocalized("Credits"))
            NanoMuseCard {
                NanoMuseRowLabel(title: "nanoMuse", chevron: false)
                NanoMuseRowDivider()
                NanoMuseRowLabel(title: AppLocalized("Based on OpenMinis 1.13"), chevron: false)
            }
            NanoMuseCaption(text: AppLocalized("Nivo Bot builds on nanoMuse and OpenMinis. Their licenses and attribution are preserved."))
        }
    }

    private func externalLink(_ title: String, _ url: URL) -> some View {
        Link(destination: url) { NanoMuseRowLabel(title: title) }.buttonStyle(.plain)
    }
}
