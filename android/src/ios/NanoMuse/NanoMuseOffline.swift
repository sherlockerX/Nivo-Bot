/// 本地构建关闭原账号、设备中继、云同步与云端提示。
/// 用户明确配置的模型API、OAuth、MCP和第三方服务仍可主动连接。
enum NanoMuseOffline {
    /// 与Android本地构建策略保持一致，不能通过旧偏好重新启用内置云服务。
    static let isOn = true
}
