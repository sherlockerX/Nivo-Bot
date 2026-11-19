package io.github.nanomuse.local

import java.net.URI
import java.util.Locale

/** 内置账号服务停用规则；用户自行添加的API、OAuth和MCP不受影响。 */
object LocalOnlyPolicy {
    /** 只识别原云实例标识或原官方中继主机，不按供应商名称或模糊域名匹配。 */
    fun isRetiredProvider(instanceId: String, baseUrl: String?, legacyInstanceId: String?): Boolean {
        if (!legacyInstanceId.isNullOrBlank() && instanceId == legacyInstanceId) return true
        val host = runCatching { URI(baseUrl?.trim().orEmpty()).host }.getOrNull()
            ?.lowercase(Locale.ROOT)?.removeSuffix(".")
        return host == "cloud.nanomuse.cn"
    }

    /** 沿用已有归属；首次升级只冻结旧标识，绝不把旧记录改为另一个账号。 */
    fun owner(saved: String?, legacyAccountId: String?, legacyToken: String?): String =
        saved ?: legacyAccountId?.takeIf { it.isNotBlank() }
            ?: legacyToken?.takeIf { it.isNotBlank() }?.hashCode()?.toString().orEmpty()
}
