package io.github.nanomuse.chat

import android.icu.lang.UCharacter
import java.text.Normalizer
import java.util.Locale

/** 分组名错误保留稳定代码，UI与CLI共用服务层校验。 */
class GroupNameException(val code: String, val existingGroupId: String? = null) : IllegalArgumentException(code)

/** 规范化展示名和完整Unicode折叠键，身份仍使用原UUID。 */
object GroupNamePolicy {
    const val SYSTEM_ID = "nm-scheduled-conversations"
    private val reserved = listOf("定时任务", "Scheduled tasks", "未分组", "Ungrouped", "Unfiled", "No group", "暂不分组", "不分组")

    /** 先拒绝控制字符，再规范化、按码点限制长度。 */
    fun display(name: String): String {
        if (name.codePoints().anyMatch { Character.isISOControl(it) }) throw GroupNameException("GROUP_NAME_INVALID")
        val result = Normalizer.normalize(name.trim(), Normalizer.Form.NFKC).trim()
        if (result.codePointCount(0, result.length) !in 1..40) throw GroupNameException("GROUP_NAME_INVALID")
        return result
    }

    /** ICU用于设备上的完整casefold；JVM的Android桩为空时仅提供测试构造回退。 */
    fun key(name: String): String {
        val normalized = Normalizer.normalize(name.trim(), Normalizer.Form.NFKC).trim()
        return UCharacter.foldCase(normalized, true) ?: normalized.lowercase(Locale.ROOT)
    }

    /** 用户入口不得占用系统或虚拟容器名称。 */
    fun validate(name: String): String = display(name).also {
        if (reserved.any { alias -> key(alias) == key(it) }) throw GroupNameException("GROUP_NAME_RESERVED")
    }

    /** 编号前按码点缩短基名，保留编号并避免拆开代理对。 */
    fun numbered(name: String, number: Int): String {
        val suffix = " ($number)"
        val base = name.takeIf { it.isNotBlank() } ?: "Group"
        val count = minOf(base.codePointCount(0, base.length), 40 - suffix.length)
        return base.substring(0, base.offsetByCodePoints(0, count)).trimEnd() + suffix
    }

    /** 旧非法名称以不含控制字符的可见基名保留，不删除分组。 */
    fun legacyBase(name: String): String {
        val printable = name.codePoints().toArray().filterNot { Character.isISOControl(it) }.toIntArray()
        val result = Normalizer.normalize(String(printable, 0, printable.size), Normalizer.Form.NFKC).trim().ifEmpty { "Group" }
        return result.substring(0, result.offsetByCodePoints(0, minOf(40, result.codePointCount(0, result.length))))
    }

    /** 系统组只能由调度创建或由用户移出，不允许普通入口改名或解散。 */
    fun protect(id: String) { if (id == SYSTEM_ID) throw GroupNameException("GROUP_SYSTEM_PROTECTED") }
}
