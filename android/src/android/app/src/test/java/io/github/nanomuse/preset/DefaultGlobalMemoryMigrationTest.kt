package io.github.nanomuse.preset

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** 默认记忆升级必须保留用户内容，同时修正身份和记录读取能力。 */
class DefaultGlobalMemoryMigrationTest {
    private val current: String
        get() {
            val relative = "src/main/assets/preset/memory/GLOBAL.md"
            val source = listOf(
                File(relative),
                File("app/$relative"),
                File("android/src/android/app/$relative"),
            ).firstOrNull { it.isFile }
            return requireNotNull(source) { "找不到预置记忆：$relative" }.readText()
        }

    @Test
    fun should_upgradeUntouchedMemory_when_legacyTemplateMatches() {
        assertEquals(current, DefaultGlobalMemoryMigration.replacement(LEGACY_CONTENT, current))
        val windowsContent = LEGACY_CONTENT.replace("\n", "\r\n")
        assertEquals(current, DefaultGlobalMemoryMigration.replacement(windowsContent, current))
    }

    @Test
    fun should_preserveUserMemory_when_anyContentWasEdited() {
        listOf(
            LEGACY_CONTENT.replace("Nicholasx", "小念"),
            LEGACY_CONTENT + "\n我每天八点起床。\n",
            LEGACY_CONTENT.replace("只保存在这台手机上", "备份到我的私人硬盘"),
            LEGACY_CONTENT.replace("你现在读不到拼图里的记录。", "只读我明确指定的日期。"),
            LEGACY_CONTENT.trimEnd(),
            "",
            " \n",
        ).forEach { assertNull(DefaultGlobalMemoryMigration.replacement(it, current)) }
    }

    @Test
    fun should_skipWrite_when_alreadyCurrentOrTargetInvalid() {
        assertNull(DefaultGlobalMemoryMigration.replacement(current, current))
        assertNull(DefaultGlobalMemoryMigration.replacement(current.replace("\n", "\r\n"), current))
        assertNull(DefaultGlobalMemoryMigration.replacement(LEGACY_CONTENT, ""))
        assertNull(DefaultGlobalMemoryMigration.replacement(LEGACY_CONTENT, LEGACY_CONTENT))
    }

    @Test
    fun should_useCurrentIdentityAndQueries_when_loadingBundledDefault() {
        assertTrue(current.contains("念步（Nelan）"))
        assertTrue(current.contains("你的名字和性格以SOUL.md为准"))
        assertTrue(current.contains("十七"))
        assertTrue(current.contains("Shiqi"))
        assertTrue(current.contains("personal_records_query"))
        assertTrue(current.contains("minis-jigsaw-cli"))
        assertTrue(current.contains("心得文字"))
        assertFalse(current.contains("每天的照片、一句话"))
        assertTrue(current.contains("查询失败不代表没有记录"))
        assertFalse(current.contains("Nicholasx"))
        assertFalse(current.contains("你现在读不到拼图里的记录"))
    }

    companion object {
        // 完整保留已发布模板，连空格与末尾换行也参与迁移判断。
        private val LEGACY_CONTENT = """
            # 长期记忆

            ## 关于你自己
            - 你是 Nicholasx，运行在我的 Android 手机上，模型来自我自己配置的服务商。
            - 你看得到 SOUL.md（你的性格）、USER.md（关于我）和这份长期记忆；每天的零碎写进当天的记忆日志。

            ## 关于"拼图"
            - "拼图"页是我的生活记录：每天的照片、一句话和习惯完成情况，只保存在这台手机上。
            - 你现在读不到拼图里的记录。需要复盘时，请我把当天或这周的内容告诉你，或者直接问我。

            ## 约定
            - 我说"记住……"时，把它写进长期记忆或 USER.md，并告诉我写在了哪里。
            - 关于我的长期事实（称呼、作息、目标、重要的人）更新到 USER.md，不要重复堆在这里。
            - 过时或被我纠正的内容，直接改掉，不要留下互相矛盾的两条。
        """.trimIndent() + "\n"
    }
}
