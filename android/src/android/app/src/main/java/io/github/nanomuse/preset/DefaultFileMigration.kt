package io.github.nanomuse.preset

import java.io.File
import java.nio.file.Files
import java.nio.file.StandardCopyOption

/** 启动时安全替换默认文件；普通编辑发生后放弃本次迁移。 */
internal object DefaultFileMigration {
    /** 唯一临时文件避免重名；不支持原子替换时抛错，交给启动层记录并在下次启动重试。 */
    @Synchronized
    fun replaceIfUnchanged(file: File, expected: String, replacement: String): Boolean {
        if (!file.isFile || file.readText() != expected) return false
        val directory = requireNotNull(file.absoluteFile.parentFile).toPath()
        val temporary = Files.createTempFile(directory, "${file.name}.brand-", ".tmp")
        try {
            Files.write(temporary, replacement.toByteArray(Charsets.UTF_8))
            // 写临时文件期间的编辑或删除均应优先，不重新创建已被用户删除的文件。
            if (!file.isFile || file.readText() != expected) return false
            Files.move(
                temporary,
                file.toPath(),
                StandardCopyOption.ATOMIC_MOVE,
                StandardCopyOption.REPLACE_EXISTING,
            )
            return true
        } finally {
            Files.deleteIfExists(temporary)
        }
    }
}
