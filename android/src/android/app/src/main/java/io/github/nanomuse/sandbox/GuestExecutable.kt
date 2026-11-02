package io.github.nanomuse.sandbox

import java.io.File
import java.nio.file.Files

/** 在客体根目录内解析解释器链接，不把绝对链接误解为Android宿主路径。 */
object GuestExecutable {
    /** 最多解析十六层链接，拒绝越界和循环。 */
    fun isPresent(root: File, path: String, readLink: (File) -> String? = { file ->
        if (Files.isSymbolicLink(file.toPath())) Files.readSymbolicLink(file.toPath()).toString() else null
    }): Boolean {
        val base = root.absoluteFile.normalize()
        var current = File(base, path.removePrefix("/")).normalize()
        repeat(16) {
            if (!current.toPath().startsWith(base.toPath())) return false
            val link = runCatching { readLink(current) }.getOrNull() ?: return current.isFile
            current = if (link.startsWith("/")) File(base, link.removePrefix("/")).normalize()
            else File(current.parentFile, link).normalize()
        }
        return false
    }
}
