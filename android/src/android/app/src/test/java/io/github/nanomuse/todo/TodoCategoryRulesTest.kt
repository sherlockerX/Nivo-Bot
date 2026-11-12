package io.github.nanomuse.todo

import org.junit.Assert.*
import org.junit.Test

/** 分类规则保持显示语义且拒绝无法复用的空名称。 */
class TodoCategoryRulesTest {
    @Test fun should_trimNamesWithoutMergingCase_when_creating() {
        assertEquals("成长", TodoCategoryRules.name("tag", "  成长  "))
        assertNotEquals(TodoCategoryRules.name("group", "Work"), TodoCategoryRules.name("group", "work"))
    }
    @Test fun should_rejectInvalidNames_when_creating() {
        listOf("" to "a", "tag" to " ", "tag" to "x".repeat(81), "group" to "a\nb", "group" to "x".repeat(201)).forEach { (kind, value) ->
            assertTrue(runCatching { TodoCategoryRules.name(kind, value) }.isFailure)
        }
    }
}
