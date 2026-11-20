import CloudKit
import Foundation

/// 为旧同步数据结构保留兼容接口，个人构建不提供任何内置iCloud连接。
enum NivoICloudPolicy {
    /// 固定关闭，旧版本保存的同步开关不能恢复云服务。
    static let isEnabled = false

    /// 不构造CloudKit容器，避免侧载签名没有云授权时抛出Objective-C异常。
    static var container: CKContainer? { nil }

    /// 旧同步或备份调用明确失败，防止把未执行操作当作已完成。
    static var unavailable: CocoaError { CocoaError(.featureUnsupported) }
}
