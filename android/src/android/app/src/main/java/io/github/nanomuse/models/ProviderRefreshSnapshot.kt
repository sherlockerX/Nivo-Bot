package io.github.nanomuse.models

import com.openminis.app.data.model.ProviderInstance

/** 网络请求的实例与实际凭证快照；凭证仅用于比较，不提供日志或序列化输出。 */
class ProviderRefreshSnapshot(instance: ProviderInstance, private val apiKey: String?) {
    private val expectedInstance = instance.copy()

    /** 调用者在配置锁内检查，只有仍存在且连接和凭证都未变化时才能提交模型列表。 */
    fun matches(current: ProviderInstance?, currentApiKey: String?): Boolean =
        current == expectedInstance && currentApiKey == apiKey
}
