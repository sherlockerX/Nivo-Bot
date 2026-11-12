package io.github.nanomuse.ideas

import java.time.Duration
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** 验证每日轮换、当地日期和热点证据的边界。 */
class DailyIdeasTest {
    private val date = LocalDate.of(2026, 11, 7)
    private val sections = DailyIdeaCategory.entries.map { category ->
        DailyIdeaSection(category, category.key, (1..14).map { index ->
            DailyIdea("${category.key}-$index", "💡", "题目$index", "说明", "提示$index")
        })
    }

    @Test
    fun should_keepCategoryOrder_when_selectingDailyIdeas() {
        val result = DailyIdeas.select(sections.reversed(), date)
        assertEquals(listOf("ideas", "work", "life", "learn", "family", "media", "more"),
            result.sections.map { it.category.key })
        assertTrue(result.sections.all { it.ideas.size == 2 })
    }

    @Test
    fun should_keepSelectionStable_when_reloadingDuringSameDay() {
        val expected = DailyIdeas.select(sections, date)
        val reloaded = sections.map { it.copy(ideas = it.ideas.reversed()) }
        assertEquals(expected, DailyIdeas.select(reloaded, date))
        assertEquals(date, expected.localDate)
    }

    @Test
    fun should_avoidRepeatsForSevenDays_when_poolHasFourteenIdeas() {
        val week = (0L..6L).map { DailyIdeas.select(sections, date.plusDays(it)) }
        DailyIdeaCategory.entries.forEach { category ->
            val ids = week.flatMap { edition ->
                edition.sections.single { it.category == category }.ideas.map { it.id }
            }
            assertEquals(14, ids.size)
            assertEquals(14, ids.toSet().size)
        }
        assertNotEquals(week[0], week[1])
        assertEquals(week[0].sections, DailyIdeas.select(sections, date.plusDays(7)).sections)
    }

    @Test
    fun should_handleSmallAndEmptyPools_when_catalogueIsIncomplete() {
        val one = sections.first().copy(ideas = sections.first().ideas.take(1))
        val empty = sections[1].copy(ideas = emptyList())
        val selected = DailyIdeas.select(listOf(one, empty), date)
        assertEquals(1, selected.sections.first().ideas.size)
        assertTrue(selected.sections[1].ideas.isEmpty())
        assertTrue(DailyIdeas.select(emptyList(), date).sections.isEmpty())
    }

    @Test
    fun should_useLocalDate_when_sameInstantFallsOnDifferentDates() {
        val now = Instant.parse("2026-11-08T02:00:00Z")
        assertEquals(LocalDate.of(2026, 11, 7), DailyIdeas.localDate(now, ZoneId.of("America/Chicago")))
        assertEquals(LocalDate.of(2026, 11, 8), DailyIdeas.localDate(now, ZoneId.of("Asia/Shanghai")))
    }

    @Test
    fun should_recalculateAtLocalMidnight_when_daylightSavingChanges() {
        val zone = ZoneId.of("America/Chicago")
        val start = Instant.parse("2026-11-01T05:00:00Z")
        assertEquals(Duration.ofHours(25), Duration.between(start, DailyIdeas.nextLocalDay(start, zone)))
        val lastSecond = Instant.parse("2026-11-02T05:59:59Z")
        assertEquals(1_000L, DailyIdeas.refreshDelayMillis(lastSecond, zone))
        assertEquals(60_000L, DailyIdeas.refreshDelayMillis(start, zone))
    }

    @Test
    fun should_requireEvidenceAndSensibleTimes_when_markingHotTopic() {
        val now = Instant.parse("2026-11-07T15:00:00Z")
        val source = DailyIdeaSource("Example", "https://example.org/story",
            now.minusSeconds(3_600), now.minusSeconds(60))
        val idea = sections.first().ideas.first().copy(isHotTopic = true, source = source)
        assertTrue(idea.hasVerifiedHotTopic(now))
        assertFalse(idea.copy(isHotTopic = false).hasVerifiedHotTopic(now))
        assertFalse(idea.copy(source = null).hasVerifiedHotTopic(now))
        assertFalse(idea.copy(source = source.copy(url = "javascript:alert(1)")).hasVerifiedHotTopic(now))
        assertFalse(idea.copy(source = source.copy(publisher = " ")).hasVerifiedHotTopic(now))
        assertFalse(idea.copy(source = source.copy(publishedAt = now.plusSeconds(60))).hasVerifiedHotTopic(now))
        assertFalse(idea.copy(source = source.copy(verifiedAt = now.plusSeconds(60))).hasVerifiedHotTopic(now))
        assertFalse(idea.copy(source = source.copy(verifiedAt = now.minusSeconds(7_200))).hasVerifiedHotTopic(now))
        assertFalse(idea.copy(source = source.copy(publishedAt = now.minusSeconds(259_200))).hasVerifiedHotTopic(now))
    }
}
