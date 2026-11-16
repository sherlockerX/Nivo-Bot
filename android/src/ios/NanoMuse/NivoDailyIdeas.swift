import SwiftUI

extension NivoDailyIdeaCategory {
    /// 分类使用界面语言，素材按安卓约定提供中英文回退。
    var title: String {
        switch self {
        case .ideas: return AppLocalized("Ideas")
        case .work: return AppLocalized("Work")
        case .life: return AppLocalized("Life")
        case .learn: return AppLocalized("Learning")
        case .family: return AppLocalized("Family and relationships")
        case .media: return AppLocalized("Content creation")
        case .more: return AppLocalized("More ideas")
        }
    }
}

/// 聊天下方的每日点子条带，保留加载行高度；点击只填入草稿。
struct NivoDailyIdeaStrip: View {
    var onSelect: (String) -> Void
    @ObservedObject private var state = NivoDailyIdeaState.shared
    @SceneStorage("nanomuse.dailyideas.category") private var categoryKey = "ideas"
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .subheadline) private var cardMinHeight: CGFloat = 70

    private var category: NivoDailyIdeaCategory { NivoDailyIdeaCategory(rawValue: categoryKey) ?? .ideas }
    private var ideas: [NivoDailyIdea] {
        state.edition.sections.first(where: { $0.category == category })?.ideas ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if category == .media {
                    Button(AppLocalized("Check stories to film today")) {
                        if let idea = state.hotTopicIdea() { onSelect(idea.prompt) }
                    }.font(.caption.weight(.medium))
                } else {
                    Text(AppLocalized("Daily ideas")).font(.caption.weight(.medium))
                    Text(state.edition.localDate, style: .date).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Button(AppLocalized("View all")) { NivoLifeNavigation.shared.open("ideas") }
                    .font(.caption.weight(.medium))
            }.lineLimit(1).frame(minHeight: 32)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(NivoDailyIdeaCategory.allCases) { item in
                        Button { categoryKey = item.rawValue } label: {
                            Text(item.title).font(.caption.weight(.medium))
                                .foregroundStyle(item == category ? Color.white : Color.primary)
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(item == category ? NanoMuseTones.action : NanoMuseTones.fill, in: Capsule())
                        }.buttonStyle(.plain)
                    }
                }.padding(.horizontal, 2)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    if ideas.isEmpty || state.errorMessage != nil { loadingCard }
                    ForEach(ideas) { idea in
                        Button { onSelect(idea.prompt) } label: {
                            card(emoji: idea.emoji, title: idea.title, body: idea.body)
                        }.buttonStyle(.plain)
                    }
                }.padding(.horizontal, 2)
            }.frame(minHeight: cardMinHeight)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .modifier(NivoDailyIdeaRefresh())
    }

    /// 首次载入和真实文字共用字体测量与保留行数，避免条带载入后再次推挤聊天。
    private func card(emoji: String, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(emoji).font(.title3)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold)).lineLimit(2, reservesSpace: true)
                if !typeSize.isAccessibilitySize {
                    Text(body).font(.caption).foregroundStyle(.secondary).lineLimit(2, reservesSpace: true)
                }
            }
        }
        .padding(10).frame(width: 250, alignment: .leading).frame(minHeight: cardMinHeight)
        .background(NanoMuseTones.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder private var loadingCard: some View {
        if state.errorMessage != nil || (!state.isLoading && ideas.isEmpty) {
            VStack(alignment: .leading) {
                Text(state.errorMessage ?? AppLocalized("The ideas could not be loaded.")).font(.caption).foregroundStyle(.secondary)
                Button(AppLocalized("Retry")) { Task { await state.refresh() } }.disabled(state.isLoading)
            }.frame(width: 250, alignment: .leading).frame(minHeight: cardMinHeight)
        } else {
            card(emoji: "💡", title: "Ag中", body: "Ag中").hidden().accessibilityHidden(true)
                .overlay { ProgressView() }
        }
    }
}
