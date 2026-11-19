package io.github.nanomuse.local

import android.content.Context
import com.openminis.app.MinisApp
import com.openminis.app.data.model.ProviderConfig
import com.openminis.app.data.model.ProviderInstance

/** 本地版服务边界；旧云配置仅留作恢复凭证，不再承担认证或网络路由。 */
object LocalOnlyMode {
    private const val PREFS = "nanomuse"
    private const val KEY_OWNER = "local.owner"
    private const val KEY_LEGACY_INSTANCE = "cloud.instance_id"

    /** 判断是否为已停用的内置云供应商。 */
    fun isRetiredProvider(context: Context?, instance: ProviderInstance): Boolean {
        val legacyId = context?.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            ?.getString(KEY_LEGACY_INSTANCE, null)
        return LocalOnlyPolicy.isRetiredProvider(instance.id, instance.customBaseURL, legacyId)
    }

    /** 保留全部配置与模型记录，只冻结原云供应商，防止启动刷新和旧聊天自动调用。 */
    fun freezeCloudProviders(context: Context, config: ProviderConfig): ProviderConfig =
        config.copy(instances = config.instances.map { instance ->
            if (isRetiredProvider(context, instance)) instance.copy(isEnabled = false) else instance
        }.toMutableList())

    /** 在任何云状态被改变前固定旧owner，不移动文件、不删除归档，也不请求远程账号。 */
    @Synchronized
    fun owner(context: Context): String {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        if (prefs.contains(KEY_OWNER)) return prefs.getString(KEY_OWNER, "").orEmpty()
        val accountId = prefs.getString("cloud.account_id", null)
        val instanceId = prefs.getString(KEY_LEGACY_INSTANCE, null)
        val token = if (accountId.isNullOrBlank() && !instanceId.isNullOrBlank()) {
            val repo = (context.applicationContext as? MinisApp)?.providerRepositoryOrNull
            checkNotNull(repo) { "Local account storage is not ready" }
            repo.loadApiKey(instanceId)
        } else null
        val owner = LocalOnlyPolicy.owner(null, accountId, token)
        check(prefs.edit().putString(KEY_OWNER, owner).commit()) { "Local owner could not be saved" }
        return owner
    }

    /** 旧入口一律本地拒绝；不允许误入账号退出、删除或联网迁移流程。 */
    fun unavailable(): Nothing = throw IllegalStateException("Built-in cloud services are unavailable in this local app")
}
