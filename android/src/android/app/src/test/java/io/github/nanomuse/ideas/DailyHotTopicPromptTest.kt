package io.github.nanomuse.ideas

import java.time.LocalDate
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** 热点入口每天存在，请求核实事实，不把待查题材写成已验证新闻。 */
class DailyHotTopicPromptTest {
    private val firstDay = LocalDate.of(2026, 11, 7)

    @Test
    fun should_offerFreshDateEveryDay_when_requestingHotTopicPrompt() {
        (0L..7L).forEach { offset ->
            val date = firstDay.plusDays(offset)
            val prompt = DailyHotTopicPrompt.create(date, "zh")
            assertTrue(prompt.contains(date.toString()))
            assertTrue(prompt.contains("主动联网"))
            assertTrue(prompt.contains("可拍"))
        }
    }

    @Test
    fun should_requireEvidenceAndFallback_when_promptIsChinese() {
        val prompt = DailyHotTopicPrompt.create(firstDay, "zh")
        listOf("至少两个", "原始", "https", "发布时间", "核验时间", "事件发生时间",
            "不能", "旧闻", "无法联网", "常青选题", "镜头", "不要发布").forEach { requirement ->
            assertTrue("缺少热点边界：$requirement", prompt.contains(requirement))
        }
        assertFalse(prompt.contains("已经核实"))
    }

    @Test
    fun should_requireEvidenceAndFallback_when_languageFallsBackToEnglish() {
        val prompt = DailyHotTopicPrompt.create(firstDay, "en")
        listOf("actively browse", "at least two", "original", "https", "publication time",
            "verification time", "event date", "old news", "unavailable", "evergreen",
            "shots", "Do not publish").forEach { requirement ->
            assertTrue("缺少英文热点边界：$requirement", prompt.contains(requirement))
        }
        assertEquals(prompt, DailyHotTopicPrompt.create(firstDay, "de"))
        assertEquals(DailyHotTopicPrompt.create(firstDay, "zh"),
            DailyHotTopicPrompt.create(firstDay, "zh-TW"))
    }
}
