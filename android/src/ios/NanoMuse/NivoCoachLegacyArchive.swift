import SwiftUI

/// 历史训练仅展示旧原话与点评，不把旧分数换算为新课程的掌握状态。
struct NivoCoachLegacyArchive: View {
    @ObservedObject private var feed = NanoMuseFeedStore.shared
    @ObservedObject private var growth = NanoMuseGrowthStore.shared
    @State private var query = ""

    var body: some View {
        List {
            Section {
                Text(AppLocalized("Earlier training is kept for review. Continue learning from the Coach map; old scores do not mark new units as mastered."))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section(AppLocalized("Legacy training")) {
                ForEach(feed.posts.filter(matches)) { post in
                    NavigationLink {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 16) {
                                Text(post.title).font(.title2.bold())
                                Text(post.body).textSelection(.enabled)
                                if let response = growth.responses[post.id] { answer(response) }
                            }.padding().frame(maxWidth: 760).frame(maxWidth: .infinity)
                        }.navigationBarTitleDisplayMode(.inline)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(post.title)
                            Text(post.createdAt, style: .date).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if feed.posts.isEmpty { Text(AppLocalized("No training cards on this day.")).foregroundStyle(.secondary) }
            }
            // 原卡片超过保留期后，已保存的回答仍可回看。
            let postIDs = Set(feed.posts.map(\.id))
            let archived = growth.responses.values.filter { !postIDs.contains($0.post) }
                .sorted { $0.answeredAt > $1.answeredAt }
            if !archived.isEmpty {
                Section(AppLocalized("Growth record")) {
                    ForEach(archived, id: \.post) { response in
                        DisclosureGroup(response.prompt) { answer(response) }
                    }
                }
            }
        }
        .searchable(text: $query, prompt: AppLocalized("Search"))
        .onAppear { feed.reload(); growth.reload() }
    }

    private func matches(_ post: NanoMusePost) -> Bool {
        query.isEmpty || post.title.localizedCaseInsensitiveContains(query) || post.body.localizedCaseInsensitiveContains(query)
    }

    @ViewBuilder
    private func answer(_ response: NanoMuseGrowthResponse) -> some View {
        Text(response.answer).textSelection(.enabled)
        if let feedback = response.feedback { Text(feedback).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
        Text(response.answeredAt, style: .date).font(.caption).foregroundStyle(.secondary)
    }
}
