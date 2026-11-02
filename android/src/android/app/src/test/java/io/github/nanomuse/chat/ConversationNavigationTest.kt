package io.github.nanomuse.chat

import com.openminis.app.ui.chat.ChatMessage
import org.junit.Assert.*
import org.junit.Test

/** 检查已读语义、独立计时和稳定消息定位。 */
class ConversationNavigationTest {
    @Test fun `date picker rejects unsupported years malformed dates and future editor dates`() {
        val today = java.time.LocalDate.parse("2026-10-28")
        assertNull(io.github.nanomuse.mosaic.parseDiaryPickerDate("2026-11-01", today))
        assertNull(io.github.nanomuse.mosaic.parseDiaryPickerDate("0000-01-01", null))
        assertNull(io.github.nanomuse.mosaic.parseDiaryPickerDate("+10000-01-01", null))
        assertNull(io.github.nanomuse.mosaic.parseDiaryPickerDate("2026-02-30", null))
        assertEquals(today, io.github.nanomuse.mosaic.parseDiaryPickerDate("2026-10-28", today))
        assertNotNull(io.github.nanomuse.mosaic.parseDiaryPickerDate("9999-12-31", null))
    }
    @Test fun `completed marks clear on opening only that conversation`() {
        val ledger = ConversationRunLedger()
        ledger.start("a", 1000, "第一个任务")
        ledger.start("b", 2000, "第二个任务")
        ledger.finish("a", false)
        ledger.finish("b", false)
        ledger.setViewing("a", true)
        assertFalse(ledger.outcomes.value.containsKey("a"))
        assertEquals(true, ledger.outcomes.value["b"])
    }

    @Test fun `completion while actually viewing is read but background completion stays unread`() {
        val ledger = ConversationRunLedger()
        ledger.setViewing("a", true)
        ledger.start("a", 1000, "任务")
        ledger.finish("a", false)
        assertTrue(ledger.outcomes.value.isEmpty())
        ledger.setViewing("a", false)
        ledger.start("a", 2000, "新任务")
        ledger.finish("a", true)
        assertEquals(false, ledger.outcomes.value["a"])
        ledger.finish("a", false)
        assertEquals(false, ledger.outcomes.value["a"])
    }

    @Test fun `concurrent task clocks do not reset each other or leak after finish`() {
        val ledger = ConversationRunLedger()
        ledger.start("a", 1000, "第一行\n第二行")
        ledger.start("b", 61000, "另一件事")
        ledger.start("a", 121000, "不应重启")
        assertEquals(listOf("第一行 第二行 · 02:00", "另一件事 · 01:00"), ledger.lines(121000, "对话"))
        ledger.finish("a", false)
        assertEquals(listOf("另一件事 · 02:00"), ledger.lines(181000, "对话"))
    }

    @Test fun `anchor identities survive merged assistant UI identifiers`() {
        val old = ChatMessage(id = "old-ui", role = "assistant", content = "重要结论", sourceDbIds = listOf("db-a", "db-b"))
        val changed = old.copy(id = "new-ui")
        assertEquals("db-a", anchorIdentity(old))
        assertEquals(0, findAnchorMessage(listOf(changed), "db-a"))
        assertEquals(0, findAnchorMessage(listOf(changed), "db-b"))
        assertEquals(-1, findAnchorMessage(listOf(changed), "deleted-id"))
    }

    @Test fun `anchor directory searches text and selects question or saved records only`() {
        val messages = listOf(
            ChatMessage(id = "u1", role = "user", content = "学习计划"),
            ChatMessage(id = "a1", role = "assistant", content = "关键答案", sourceDbIds = listOf("db1")),
            ChatMessage(id = "u2", role = "user", content = "如何复习"),
        )
        assertEquals(listOf("u1", "u2"), anchorEntries(messages, emptySet(), "", false).map { it.id })
        assertEquals(listOf("db1"), anchorEntries(messages, setOf("db1"), "", true).map { it.id })
        assertEquals(listOf("db1"), anchorEntries(messages, emptySet(), "关键", false).map { it.id })
    }
}
