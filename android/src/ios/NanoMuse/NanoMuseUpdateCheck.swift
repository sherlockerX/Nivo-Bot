import Combine
import Foundation

/// 本分支的iOS更新检查；仅用户打开说明页后手动请求，结果最多缓存一天。
@MainActor
final class NanoMuseUpdateCheck: ObservableObject {
    static let shared = NanoMuseUpdateCheck()
    nonisolated static let indexURL = NivoProduct.releases.absoluteString
    nonisolated static let githubURL = "https://api.github.com/repos/sherlockerX/Nicholasx/releases/latest"
    nonisolated static let fallbackReleasePage = NivoProduct.downloads.absoluteString
    nonisolated static let downloadPage = NivoProduct.downloads.absoluteString
    typealias Found = NivoReleaseCatalog.Release

    private enum Keys {
        // 独立缓存命名避免旧上游版本污染本分支的更新状态。
        static let latest = "nivo.ios.update.latest"
        static let page = "nivo.ios.update.page"
        static let checkedAt = "nivo.ios.update.checked_at"
        static let unpublished = "nivo.ios.update.unpublished"
    }
    private static let ttl: TimeInterval = 24 * 60 * 60
    @Published private(set) var latest: String?
    @Published private(set) var page: String?
    @Published private(set) var checkedAt: Date?
    @Published private(set) var checking = false
    @Published private(set) var isUnpublished = false
    @Published private(set) var lastCheckFailed = false

    private init() {
        let defaults = UserDefaults.standard
        latest = defaults.string(forKey: Keys.latest)
        page = defaults.string(forKey: Keys.page)
        isUnpublished = defaults.bool(forKey: Keys.unpublished)
        let timestamp = defaults.double(forKey: Keys.checkedAt)
        checkedAt = timestamp > 0 ? Date(timeIntervalSince1970: timestamp) : nil
    }

    /// 始终显示安装包实际版本，不根据网站的Android版本改写。
    nonisolated static var installed: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }
    nonisolated static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
    }
    nonisolated static var installedLine: String { build.isEmpty ? installed : "\(installed) (\(build))" }
    var installedLine: String { Self.installedLine }

    var latestLine: String {
        if checking { return AppLocalized("Checking for the latest release…") }
        if lastCheckFailed { return AppLocalized("Could not check. Tap to try again") }
        if isUnpublished { return AppLocalized("An iOS release is not available yet.") }
        guard let latest else { return AppLocalized("Check for updates") }
        return latestIsNewer
            ? String(format: AppLocalized("%@ is out. Tap to update"), Self.normalize(latest))
            : String(format: AppLocalized("Latest %@. You have it"), Self.normalize(latest))
    }

    var latestIsNewer: Bool {
        guard !isUnpublished, let latest else { return false }
        return Self.compareVersions(latest, Self.installed) > 0
    }
    var releasePage: URL { URL(string: page ?? "") ?? NivoProduct.downloads }

    /// 失败显示真实检查状态；明确未发布会清除旧更新提示，不退回Android发行记录。
    func checkNow() async {
        guard !checking else { return }
        checking = true
        defer { checking = false }
        guard let result = await Self.fetchLatest() else { lastCheckFailed = true; return }
        lastCheckFailed = false
        switch result {
        case .available(let release):
            latest = release.version
            page = release.page
            isUnpublished = false
        case .unpublished:
            latest = nil
            page = nil
            isUnpublished = true
        }
        checkedAt = Date()
        let defaults = UserDefaults.standard
        defaults.set(latest, forKey: Keys.latest)
        defaults.set(page, forKey: Keys.page)
        defaults.set(isUnpublished, forKey: Keys.unpublished)
        defaults.set(checkedAt?.timeIntervalSince1970, forKey: Keys.checkedAt)
    }

    /// 供需要每日检查的入口调用；重复请求共用进行中状态。
    func checkIfStale() {
        if let checkedAt, Date().timeIntervalSince(checkedAt) < Self.ttl { return }
        Task { await checkNow() }
    }

    private static func fetchLatest() async -> NivoReleaseCatalog.Lookup? {
        if let json = await fetchJSON(indexURL), let found = NivoReleaseCatalog.lookup(json) { return found }
        if let json = await fetchJSON(githubURL), let found = parseGitHubLatest(json) { return .available(found) }
        return nil
    }

    /// 旧调用入口沿用相同平台校验，不再接受没有平台说明的通用版本标签。
    nonisolated static func parseIndex(_ json: [String: Any]) -> Found? {
        if case .available(let release) = NivoReleaseCatalog.lookup(json) { return release }
        return nil
    }
    nonisolated static func parseGitHubLatest(_ json: [String: Any]) -> Found? { NivoReleaseCatalog.github(json) }
    nonisolated static func normalize(_ version: String) -> String { NivoReleaseCatalog.normalize(version) }
    nonisolated static func compareVersions(_ first: String, _ second: String) -> Int {
        NivoReleaseCatalog.compareVersions(first, second)
    }

    private static func fetchJSON(_ address: String) async -> [String: Any]? {
        guard let url = URL(string: address) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Nivo-iOS/\(installed)", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0),
              data.count <= 2 * 1_024 * 1_024 else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
