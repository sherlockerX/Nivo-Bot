import Foundation

/// 本分支的公开入口集中维护，服务协议标识与本机数据目录不随品牌更名。
enum NivoProduct {
    static let name = "Nivo Bot"
    static let website = URL(string: "https://nivo.8666886.xyz/")!
    static let privacy = website.appendingPathComponent("privacy.html")
    static let modelGuide = website.appendingPathComponent("models.html")
    static let downloads = website.appendingPathComponent("downloads.html")
}
