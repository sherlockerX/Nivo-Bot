package io.github.nanomuse.chat

import org.junit.Assert.*
import org.junit.Test

/** JVM覆盖可见名验证；完整ICU折叠另外在Android上验收。 */
class GroupNamePolicyTest {
    @Test fun should_normalizeTrimAndCompatibilityCharacters_when_validating() {
        assertEquals("ABC", GroupNamePolicy.validate(" ＡＢＣ "))
        assertEquals(GroupNamePolicy.key("A"), GroupNamePolicy.key(" a "))
    }
    @Test fun should_countCodePointsAndRejectControls_when_validating() {
        val forty = "🐛".repeat(40)
        assertEquals(forty, GroupNamePolicy.validate(forty))
        listOf("", "  ", "🐛".repeat(41), "a\nb", "\tname").forEach {
            assertEquals("GROUP_NAME_INVALID", assertThrows(GroupNameException::class.java) { GroupNamePolicy.validate(it) }.code)
        }
    }
    @Test fun should_reserveNamesAcrossLanguages_when_validating() {
        listOf("定时任务", " SCHEDULED TASKS ", "未分组", "Ungrouped").forEach {
            assertEquals("GROUP_NAME_RESERVED", assertThrows(GroupNameException::class.java) { GroupNamePolicy.validate(it) }.code)
        }
        assertEquals("GROUP_SYSTEM_PROTECTED", assertThrows(GroupNameException::class.java) {
            GroupNamePolicy.protect(GroupNamePolicy.SYSTEM_ID) }.code)
    }
    @Test fun should_keepNumberSuffixWithinLimit_when_migratingLongNames() {
        val renamed = GroupNamePolicy.numbered("🐛".repeat(40), 12)
        assertTrue(renamed.endsWith(" (12)"))
        assertTrue(renamed.codePointCount(0, renamed.length) <= 40)
        assertFalse(renamed.first().isLowSurrogate())
    }
}
