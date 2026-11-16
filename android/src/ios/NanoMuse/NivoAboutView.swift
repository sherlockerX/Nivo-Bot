import SwiftUI
import UIKit

/// 关于页沿用设置的卡片、字号和返回方式，公开入口指向本分支并保留上游致谢。
struct NivoAboutView: View {
    @ObservedObject private var updates = NanoMuseUpdateCheck.shared
    @Environment(\.openURL) private var openURL
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
                Text(updates.installedLine).font(.subheadline).foregroundStyle(.secondary).textSelection(.enabled)
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
                NanoMuseRowDivider()
                externalLink(AppLocalized("Downloads"), NivoProduct.downloads)
                NanoMuseRowDivider()
                Button {
                    if updates.latestIsNewer && !updates.lastCheckFailed { openURL(updates.releasePage) }
                    else { Task { await updates.checkNow() } }
                } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(AppLocalized("Check for updates")).font(.body)
                            Text(updates.latestLine).font(.footnote).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        if updates.checking { ProgressView() }
                        else { Image(systemName: "arrow.clockwise").foregroundStyle(NanoMuseTones.action) }
                    }
                    .padding(16).contentShape(Rectangle())
                }
                .buttonStyle(.plain).disabled(updates.checking)
            }

            NanoMuseCard {
                externalLink(AppLocalized("GitHub Repository"), NivoProduct.repository)
                NanoMuseRowDivider()
                externalLink(AppLocalized("Report an Issue"), NanoMuseLinks.newIssue())
                NanoMuseRowDivider()
                externalLink(AppLocalized("Privacy policy"), NivoProduct.privacy)
                NanoMuseRowDivider()
                NanoMuseRowLabel(title: AppLocalized("License"), value: "GPL-3.0-or-later", chevron: false)
            }

            NanoMuseCaption(text: AppLocalized("Credits"))
            NanoMuseCard {
                externalLink("nanoMuse", URL(string: "https://github.com/nano-muse/nanoMuse")!)
                NanoMuseRowDivider()
                externalLink(AppLocalized("Based on OpenMinis 1.13"), URL(string: "https://github.com/OpenMinis/OpenMinis")!)
            }
            NanoMuseCaption(text: AppLocalized("Nivo Bot builds on nanoMuse and OpenMinis. Their licenses and attribution are preserved."))
            NanoMuseCaption(text: AppLocalized("Muse is a trademark of Meta Platforms, Inc. nanoMuse is an independent free-software project."))
        }
    }

    private func externalLink(_ title: String, _ url: URL) -> some View {
        Link(destination: url) { NanoMuseRowLabel(title: title) }.buttonStyle(.plain)
    }
}
