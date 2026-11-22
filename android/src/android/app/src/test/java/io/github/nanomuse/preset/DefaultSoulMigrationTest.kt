package io.github.nanomuse.preset

import com.openminis.app.agent.SoulStore
import io.github.nanomuse.identity.AssistantIdentity
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** 品牌迁移只能更新未编辑的默认身份，不能覆盖用户的名字与人格。 */
class DefaultSoulMigrationTest {
    private val current = SoulStore.DEFAULT_CONTENT

    @Test fun should_migrateUntouchedLegacyTemplates_when_exactlyMatching() {
        listOf("Nivo Bot", "Nicholasx", "nanoMuse").forEach { name ->
            val legacy = current.replaceFirst("name: \"Shiqi\"", "name: \"$name\"")
            assertEquals(current, DefaultSoulMigration.replacement(legacy, current))
            assertEquals(current, DefaultSoulMigration.replacement(legacy.replace("\n", "\r\n"), current))
        }
    }

    @Test fun should_preserveCustomIdentity_when_nameBodyOrFieldsChanged() {
        val legacy = current.replaceFirst("name: \"Shiqi\"", "name: \"Nivo Bot\"")
        listOf(
            current.replaceFirst("name: \"Shiqi\"", "name: \"小念\""),
            legacy + "\n请用我喜欢的方式回答。\n",
            legacy.replace("style: \"\"", "style: \"简短\""),
            legacy.replace("lang: \"zh\"", "lang: \"en\""),
            legacy.replace("style: \"\"", "icon: \"🐈\"\nstyle: \"\""),
        ).forEach { assertNull(DefaultSoulMigration.replacement(it, current)) }
    }

    @Test fun should_notWriteAgain_when_alreadyMigrated() {
        assertNull(DefaultSoulMigration.replacement(current, current))
    }

    @Test fun should_localizeDefaultOnly_when_displayingAssistant() {
        assertEquals("十七", AssistantIdentity.displayName("Shiqi", "十七"))
        assertEquals("Shiqi", AssistantIdentity.displayName("十七", "Shiqi"))
        assertEquals("十七", AssistantIdentity.displayName(" ", "十七"))
        listOf("Nivo Bot", "Nicholasx", "nanoMuse", "小念", "Nelan", " 小念 ").forEach {
            assertEquals(it, AssistantIdentity.displayName(it, "十七"))
        }
    }
}
