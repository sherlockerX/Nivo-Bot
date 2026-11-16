import Foundation

/// 备份租约和档案格式错误，界面文案由宿主本地化扩展提供。
enum NivoPersonalBackupError: Error {
    case busy, chatRunning, snapshotChanged, invalidPackage
}
