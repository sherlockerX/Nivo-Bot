package io.github.nanomuse.preset

import io.github.nanomuse.identity.AssistantIdentity

/** 只迁移完整的旧默认模板，不以昵称或正文片段判断用户是否修改过身份。 */
internal object DefaultSoulMigration {
    private val LEGACY_NAMES = listOf("Nivo Bot", "Nicholasx", "nanoMuse")

    /** 返回待替换内容；自定义正文、昵称、附加字段及已迁移内容均返回null。 */
    fun replacement(source: String, defaultContent: String): String? {
        val normalized = source.replace("\r\n", "\n")
        val current = defaultContent.replace("\r\n", "\n")
        val defaultHeader = "name: \"${AssistantIdentity.DEFAULT_NAME}\""
        if (!current.startsWith("---\n$defaultHeader\n")) return null
        val matchesLegacy = LEGACY_NAMES.any { legacyName ->
            normalized == current.replaceFirst(defaultHeader, "name: \"$legacyName\"")
        }
        return defaultContent.takeIf { matchesLegacy }
    }
}
