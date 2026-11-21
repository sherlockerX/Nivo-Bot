import Foundation

/// 本分支的公开入口集中维护，服务协议标识与本机数据目录不随品牌更名。
enum NivoProduct {
    static let englishName = "Nelan"
    /// 界面每次读取当前语言，独立Swift包不依赖主App的本地化实现。
    static var name: String {
        #if SWIFT_PACKAGE
        englishName
        #else
        AppLocalized("Nelan")
        #endif
    }
    /// 仅用于新建或空昵称，已有个人昵称由各入口原样保留。
    static var assistantName: String {
        #if SWIFT_PACKAGE
        "Shiqi"
        #else
        AppLocalized("Shiqi")
        #endif
    }
    static let website = URL(string: "https://nivo.8666886.xyz/")!
    static let privacy = website.appendingPathComponent("privacy.html")
    static let modelGuide = website.appendingPathComponent("models.html")
    static let downloads = website.appendingPathComponent("downloads.html")
}
