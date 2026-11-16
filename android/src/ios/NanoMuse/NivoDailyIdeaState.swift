import SwiftUI
import UIKit

/// 主聊天与完整点子页共享当天版本，旧语言的迟到读取不会覆盖新语言。
@MainActor
final class NivoDailyIdeaState: ObservableObject {
    static let shared = NivoDailyIdeaState()
    @Published private(set) var edition = NivoDailyIdeaEdition(localDate: Date(), sections: [])
    @Published private(set) var isLoading = true
    @Published private(set) var errorMessage: String?
    private var language: String?
    private var requestID = UUID()

    /// 磁盘读取在目录actor中执行，前台定期检查只重新选取缓存中的素材。
    func refresh() async {
        let requestedLanguage = NanoMuseLocale.isChinese ? "zh" : "en"
        let token = UUID()
        requestID = token
        if language != requestedLanguage {
            language = requestedLanguage
            edition = NivoDailyIdeaEdition(localDate: Date(), sections: [])
        }
        isLoading = edition.sections.isEmpty
        defer { if requestID == token { isLoading = false } }
        do {
            let sections = try await NivoDailyIdeaCatalogue.shared.load(language: requestedLanguage)
            // 目录属于两个页面共享的数据；一个页面退出只取消轮询，不能让另一个页面空等一分钟。
            guard requestID == token else { return }
            let current = NivoDailyIdeas.edition(sections: sections, for: Date(), calendar: .current)
            if edition != current { edition = current }
            errorMessage = nil
        } catch {
            guard requestID == token else { return }
            errorMessage = AppLocalized("The ideas could not be loaded.")
        }
    }

    /// 热点入口保留显示时的日期，模板明确要求发送后重新核实日期和来源。
    func hotTopicIdea() -> NivoDailyIdea? {
        do {
            let prompt = try NivoDailyIdeas.hotTopicPrompt(for: edition.localDate,
                language: NanoMuseLocale.isChinese ? "zh" : "en", calendar: .current)
            return NivoDailyIdea(id: "daily-check-hot-topic", category: .media, emoji: "📰",
                title: AppLocalized("Check stories to film today"),
                body: AppLocalized("Evergreen topics. Current stories need sources and date checks."), prompt: prompt)
        } catch {
            errorMessage = AppLocalized("The ideas could not be loaded.")
            return nil
        }
    }
}

/// 页面隐藏或应用离开前台时取消轮询，恢复、语言变化与设备校时均立即重新核对。
struct NivoDailyIdeaRefresh: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.locale) private var locale
    @ObservedObject private var state = NivoDailyIdeaState.shared

    private var refreshKey: String {
        "\(scenePhase == .active)-\(NanoMuseLocale.isChinese)-\(locale.identifier)"
    }

    func body(content: Content) -> some View {
        content
            .task(id: refreshKey) {
                guard scenePhase == .active else { return }
                while !Task.isCancelled {
                    await state.refresh()
                    let delay = NivoDailyIdeas.refreshDelay(now: Date(), calendar: .current)
                    do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
                    catch { return }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
                guard scenePhase == .active else { return }
                Task { await state.refresh() }
            }
    }
}
