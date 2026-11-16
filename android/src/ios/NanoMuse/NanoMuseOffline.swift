/// 个人构建关闭Star提示、中继提示拉取及中继会话同步三个入口。
/// 此策略不是全局断网开关；账号、已配置模型、设备互联及iCloud仍遵循各自设置。
enum NanoMuseOffline {
    /// 与安卓MosaicOffline策略对应，由三个入口直接读取。
    static let isOn = true
}
