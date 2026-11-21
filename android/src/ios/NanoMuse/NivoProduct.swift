import Foundation

/// 本分支的公开入口集中维护，服务协议标识与本机数据目录不随品牌更名。
enum NivoProduct {
    static let name = "Nivo"
    /// 服务商注册与诊断使用同一名称，不受设备语言影响。
    static let englishName = name
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
