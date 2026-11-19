import Foundation

/// 本地清单纯解析规则，只接受明确的iOS发行记录，不请求或检查在线更新。
enum NivoReleaseCatalog {
    struct Release: Equatable, Sendable {
        var version: String
        var page: String?
    }

    enum Lookup: Equatable, Sendable {
        case available(Release)
        case unpublished
    }

    /// 网站声明平台尚未发布时保留这一事实；列表顺序不影响最高稳定版本的选择。
    static func lookup(_ json: [String: Any]) -> Lookup? {
        guard json["schemaVersion"] as? Int == 2,
              let platforms = json["platforms"] as? [[String: Any]],
              let platform = platforms.first(where: { $0["id"] as? String == "ios" }) else { return nil }
        if platform["status"] as? String == "unreleased" { return .unpublished }
        guard platform["status"] as? String == "available", let rows = json["releases"] as? [[String: Any]] else { return nil }
        let candidates = rows.compactMap { row -> Release? in
            guard row["platform"] as? String == "ios", row["channel"] as? String == "stable",
                  let version = row["version"] as? String, isValidVersion(version),
                  !normalize(version).contains("-"),
                  let address = row["downloadUrl"] as? String,
                  isInstallAddress(address, distribution: row["distribution"] as? String) else { return nil }
            return Release(version: version, page: NivoProduct.downloads.absoluteString)
        }
        guard let newest = candidates.max(by: { compareVersions($0.version, $1.version) < 0 }) else { return nil }
        return .available(newest)
    }

    /// 版本号只去除可选v前缀，不把任意文字中的数字拼成版本。
    static func normalize(_ version: String) -> String {
        var result = version.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.hasPrefix("v") || result.hasPrefix("V") { result.removeFirst() }
        return result
    }

    static func isValidVersion(_ version: String) -> Bool {
        normalize(version).range(of: #"^[0-9]+(?:\.[0-9]+){1,3}(?:-[0-9A-Za-z]+(?:\.[0-9A-Za-z]+)*)?(?:\+[0-9A-Za-z]+(?:\.[0-9A-Za-z]+)*)?$"#,
            options: .regularExpression) != nil && version.utf8.count <= 128
    }

    /// 数字段按数值比较，正式版高于预发布版，构建元数据不参与排序。
    static func compareVersions(_ first: String, _ second: String) -> Int {
        let left = parts(first)
        let right = parts(second)
        for index in 0..<max(left.numbers.count, right.numbers.count) {
            let result = compareNumber(index < left.numbers.count ? left.numbers[index] : "0",
                                       index < right.numbers.count ? right.numbers[index] : "0")
            if result != 0 { return result }
        }
        if left.labels.isEmpty { return right.labels.isEmpty ? 0 : 1 }
        if right.labels.isEmpty { return -1 }
        for (leftLabel, rightLabel) in zip(left.labels, right.labels) where leftLabel != rightLabel {
            let leftNumeric = leftLabel.allSatisfy(\.isNumber)
            let rightNumeric = rightLabel.allSatisfy(\.isNumber)
            if leftNumeric && rightNumeric {
                let comparison = compareNumber(leftLabel, rightLabel)
                if comparison != 0 { return comparison }
                continue
            }
            if leftNumeric != rightNumeric { return leftNumeric ? -1 : 1 }
            return leftLabel < rightLabel ? -1 : 1
        }
        return left.labels.count == right.labels.count ? 0 : (left.labels.count < right.labels.count ? -1 : 1)
    }

    private static func parts(_ version: String) -> (numbers: [String], labels: [String]) {
        let withoutBuild = normalize(version).split(separator: "+", maxSplits: 1).first.map(String.init) ?? ""
        let split = withoutBuild.split(separator: "-", maxSplits: 1).map(String.init)
        return ((split.first ?? "").split(separator: ".").map(String.init),
                split.count == 2 ? split[1].split(separator: ".").map(String.init) : [])
    }

    private static func compareNumber(_ first: String, _ second: String) -> Int {
        let left = String(first.drop(while: { $0 == "0" }))
        let right = String(second.drop(while: { $0 == "0" }))
        if left.count != right.count { return left.count < right.count ? -1 : 1 }
        return left == right ? 0 : (left < right ? -1 : 1)
    }

    private static func isInstallAddress(_ address: String, distribution: String?) -> Bool {
        guard let url = URL(string: address), url.scheme == "https", url.user == nil, url.password == nil else { return false }
        switch distribution {
        case "testflight": return url.host == "testflight.apple.com" && url.path.hasPrefix("/join/")
        case "appstore": return url.host == "apps.apple.com" && !url.path.isEmpty
        case "ipa": return isProjectAddress(address) && url.pathExtension.lowercased() == "ipa"
        default: return false
        }
    }

    private static func isProjectAddress(_ address: String) -> Bool {
        guard let url = URL(string: address), url.scheme == "https", url.user == nil, url.password == nil else { return false }
        return url.host == NivoProduct.website.host
    }
}
