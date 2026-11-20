package io.github.nanomuse.models

import com.openminis.app.data.model.ProviderInstance

/** 先确认凭证持久化，再公开供应商配置，避免留下显示成功但缺少密钥的供应商。 */
object ProviderCreation {
    /** 重试由表单提供同一实例ID；配置失败时保留未公开的凭证供重试覆盖。 */
    fun save(
        instance: ProviderInstance,
        apiKey: String,
        commitCredential: (String, String?) -> Boolean,
        commitInstance: (ProviderInstance) -> Unit,
        isAlreadySaved: () -> Boolean = { false },
    ): Boolean {
        // 页面重建可能先于旧协程返回，已公开的ID只能视为成功重试，不能重写密钥或端点。
        if (isAlreadySaved()) return false
        check(commitCredential(instance.id, apiKey.trim().ifBlank { null })) {
            "provider_credential_not_saved"
        }
        commitInstance(instance)
        return true
    }
}
