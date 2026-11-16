import Foundation

/// 旧提供商配置的兼容入口，持久化迁移逻辑集中在NanoMuse模块。
@MainActor
enum ProviderMigration {
    // nanoMuse: 等待凭证和配置确认后再启动依赖配置的初始化。
    /// 多窗口共享一次迁移，失败在模型设置中保留可重试状态。
    @discardableResult
    static func migrateIfNeeded(store: ProviderConfigStore) async -> Bool {
        await NivoProviderMigrationStatus.shared.run(store: store)
    }

    /// 默认组和模型刷新必须在迁移之后运行，避免与权威数据库载入互相覆盖。
    static func prepareModels(store: ProviderConfigStore) async {
        guard await migrateIfNeeded(store: store) else { return }
        store.refreshAllModelsIfNeeded()
        store.migrateVoiceModalityIfNeeded()
        await store.createDefaultGroupIfNeeded()
    }
}
