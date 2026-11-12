package io.github.nanomuse.coach

import java.io.File
import javax.xml.parsers.DocumentBuilderFactory
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** 建课材料和旧入口必须遵守同一份草案确认协议。 */
class CoachBuilderProtocolTest {
    @Test fun should_useNativeDraftLifecycle_when_loadingBundledBuilder() {
        val skill = source("src/main/assets/preset/skills/growth-course-builder/SKILL.md").readText()
        assertTrue(skill.contains("## Coach原生协议"))
        listOf("coach_query", "new_draft", "propose", "activate", "draftRevision").forEach {
            assertTrue("缺少原生建课动作：$it", skill.contains(it))
        }
        assertTrue(skill.contains("禁止直接写入"))
        assertTrue(skill.contains("后续"))
        assertFalse(skill.contains("7. 写文件"))
        assertFalse(skill.contains("教练页从下一张卡起按新课程训练"))
    }

    @Test fun should_redirectGeneralFallback_when_oldTrainingMaterialIsLoaded() {
        val skill = source("src/main/assets/preset/skills/growth-general/SKILL.md").readText()
        assertTrue(skill.contains("coach_command"))
        assertTrue(skill.contains("new_draft"))
        assertTrue(skill.contains("旧卡片历史"))
        assertFalse(skill.contains("选 10 本书、逐本拆书、写出分级课程"))
    }

    @Test fun should_requestReviewBeforeActivation_when_legacyEntryBuildsLocalizedPrompt() {
        listOf("values", "values-zh").forEach { locale ->
            val document = DocumentBuilderFactory.newInstance().newDocumentBuilder()
                .parse(source("src/main/res/$locale/nm_growth_strings.xml"))
            val nodes = document.getElementsByTagName("string")
            val text = (0 until nodes.length).map { nodes.item(it) }.single {
                it.attributes.getNamedItem("name").nodeValue == "nm_growth_build_opener"
            }.textContent
            listOf("coach_query", "new_draft", "propose", "activate", "draftRevision").forEach {
                assertTrue("$locale 缺少协议动作：$it", text.contains(it))
            }
            assertFalse(text.contains("Course folder:"))
            assertFalse(text.contains("课程文件夹："))
            assertFalse(text.contains("write the book cards"))
        }
    }

    private fun source(relative: String): File = listOf(relative, "app/$relative", "android/src/android/app/$relative")
        .map(::File).first { it.isFile }
}
