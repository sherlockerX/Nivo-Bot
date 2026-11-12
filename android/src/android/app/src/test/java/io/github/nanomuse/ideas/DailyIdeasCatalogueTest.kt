package io.github.nanomuse.ideas

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** 验证实际内置素材，防止中英文内容池和每日规则脱节。 */
class DailyIdeasCatalogueTest {
    @Test
    fun should_offerMatchingEvergreenPools_when_loadingBothLanguages() {
        val english = load("en")
        val chinese = load("zh")
        assertEquals(DailyIdeaCategory.entries, english.map { it.category })
        assertEquals(english.map { it.category }, chinese.map { it.category })
        assertEquals(english.flatMap { it.ideas }.map { it.id }, chinese.flatMap { it.ideas }.map { it.id })
        listOf(english, chinese).forEach { sections ->
            assertTrue(sections.all { it.title.isNotBlank() && it.ideas.size >= 14 })
            val ideas = sections.flatMap { it.ideas }
            assertEquals(ideas.size, ideas.map { it.id }.toSet().size)
            assertTrue(ideas.all { it.title.isNotBlank() && it.body.isNotBlank() && it.prompt.isNotBlank() })
            assertFalse(ideas.any { it.isHotTopic || it.source != null })
            assertTrue(sections.single { it.category == DailyIdeaCategory.MEDIA }.ideas.any {
                it.id == "media-verify-news" && it.prompt.contains("https")
            })
        }
    }

    @Test
    fun should_rejectInvalidNewsEvidence_when_parsingCatalogue() {
        val sections = DailyIdeas.parse("""{"sections":[{"id":"media","title":"Media","ideas":[
            {"id":"sample","title":"Sample","body":"Body","prompt":"Prompt","hot":true,
             "source":{"publisher":"Example","url":"https://example.org","publishedAt":"invalid"}}
        ]}]}""")
        assertEquals(1, sections.single().ideas.size)
        assertFalse(sections.single().ideas.single().hasVerifiedHotTopic(java.time.Instant.now()))
    }

    private fun load(language: String): List<DailyIdeaSection> {
        val relative = "src/main/assets/nanomuse/daily-ideas.$language.json"
        val source = listOf(File(relative), File("app/$relative"),
            File("android/src/android/app/$relative")).firstOrNull { it.isFile }
        requireNotNull(source) { "找不到测试素材：$relative" }
        return DailyIdeas.parse(source.readText())
    }
}
