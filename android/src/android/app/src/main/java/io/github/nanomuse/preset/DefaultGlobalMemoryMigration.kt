package io.github.nanomuse.preset

import java.security.MessageDigest

/** 只升级完整且未编辑的旧预置记忆，不按昵称或局部句子覆盖用户记忆。 */
internal object DefaultGlobalMemoryMigration {
    private val LEGACY_HASHES = setOf(
        "5ac1e61e9c4701dde95bfa79d85359637991bd8a7ef149dc3903e713c1e137f2", // 初版预置记忆
        "f5202330ddf8c2f2114560da1b10325ae85af85d903e91905c5dca990688a68c", // 2.0.9原文
    )

    /** 返回新模板；自定义、清空、已迁移或无效目标模板均保持原样。 */
    fun replacement(source: String, defaultContent: String): String? {
        val normalized = source.replace("\r\n", "\n")
        if (defaultContent.isBlank() || normalized == defaultContent.replace("\r\n", "\n")) {
            return null
        }
        val digest = MessageDigest.getInstance("SHA-256")
            .digest(normalized.toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it) }
        return defaultContent.takeIf { digest in LEGACY_HASHES }
    }
}
