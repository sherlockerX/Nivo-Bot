package io.github.nanomuse.connectors

import android.content.Context
import java.io.File
import java.security.MessageDigest
import org.json.JSONObject

/** 读取短期健康状态，旧配置结果不能阻挡用户修复后重试。 */
object McpHealth {
    /** 配置变更、过期、无法读取均返回unknown，而非永久停用服务器。 */
    fun state(context: Context, serverId: String): String = runCatching {
        val directory = File(context.filesDir, "minis-global/mcp-servers")
        val entry = JSONObject(File(directory, "health/${digest(serverId.toByteArray())}.json").readText())
        val age = System.currentTimeMillis() - entry.getLong("checked_at_ms")
        if (age !in 0..300_000 || entry.optString("signature") != digest(File(directory, "servers.json").readBytes())) "unknown"
        else entry.getString("status")
    }.getOrDefault("unknown")

    private fun digest(bytes: ByteArray): String = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
}
