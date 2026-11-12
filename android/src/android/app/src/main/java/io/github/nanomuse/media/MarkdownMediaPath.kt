package io.github.nanomuse.media

import java.io.File
import java.net.URLDecoder

/** 只计算所属会话或明确共享目录的媒体路径，不查询磁盘或其他会话。 */
object MarkdownMediaPath {
    private val SESSION_DIRECTORIES = setOf("attachments", "workspace", "offloads", "browser")
    private val SHARED_DIRECTORIES = setOf("memory", "skills", "shared", "mcp-servers", "home")

    /** 只把合法mount路径交给明确绑定解析器；调用方负责在IO线程检查文件。 */
    fun resolveMounted(
        url: String,
        sessionId: String?,
        canonicalSession: (String) -> String = { it },
        resolveBinding: (String, String) -> File?,
    ): File? {
        val owner = sessionId?.let(canonicalSession) ?: return null
        if (!isSafeRelative(owner) || '/' in owner) return null
        val decoded = if (url.startsWith("/var/minis/")) url else try {
            URLDecoder.decode(url.substringBefore('?').replace("+", "%2B"), "UTF-8")
        } catch (_: IllegalArgumentException) { return null }
        val relative = when {
            decoded.startsWith("minis://mounts/") -> decoded.removePrefix("minis://")
            decoded.startsWith("/var/minis/mounts/") -> decoded.removePrefix("/var/minis/")
            else -> return null
        }
        if (!isSafeRelative(relative) || relative.split('/').size < 3) return null
        return resolveBinding(owner, "/var/minis/$relative")
    }

    /** 保留文件名中的加号和井号，仅解码一次URL百分号转义。 */
    fun resolve(
        filesDir: File,
        url: String,
        sessionId: String?,
        canonicalSession: (String) -> String = { it },
    ): File? {
        if (url.startsWith("/var/minis/")) {
            return resolveRelative(filesDir, url.removePrefix("/var/minis/"), sessionId, canonicalSession)
        }
        if (url.startsWith("/")) return File(url)
        val encoded = url.substringBefore('?')
        val decoded = try {
            URLDecoder.decode(encoded.replace("+", "%2B"), "UTF-8")
        } catch (_: IllegalArgumentException) { return null }
        if (decoded.startsWith("file:///")) return File(decoded.removePrefix("file://"))
        if (!decoded.startsWith("minis://")) return null
        return resolveRelative(filesDir, decoded.removePrefix("minis://"), sessionId, canonicalSession)
    }

    private fun resolveRelative(
        filesDir: File,
        relative: String,
        sessionId: String?,
        canonicalSession: (String) -> String,
    ): File? {
        if (!isSafeRelative(relative)) return null
        val directory = relative.substringBefore('/')
        if (directory in SHARED_DIRECTORIES) return File(filesDir, "minis-global/$relative")
        if (directory !in SESSION_DIRECTORIES || sessionId == null) return null
        val owner = canonicalSession(sessionId)
        if (owner.isBlank() || !isSafeRelative(owner) || '/' in owner) return null
        return File(filesDir, "minis-sessions/$owner/$relative")
    }

    private fun isSafeRelative(value: String): Boolean =
        value.isNotEmpty() && '\\' !in value && '\u0000' !in value &&
            value.split('/').none { it.isEmpty() || it == "." || it == ".." }
}
