package io.github.nanomuse.chat

import org.junit.Assert.*
import org.junit.Test

/** 验证两条排队输入合并后只有真实消息ID，新入队内容保持原样。 */
class QueuedUserPromotionTest {
    private data class Bubble(val id: String, val queue: String? = null)

    @Test fun should_replaceEntireCommittedBatchWithSavedId() {
        val history = Bubble("old-user")
        val later = Bubble("queued_msg_later", "later")
        val saved = Bubble("database-user")
        val result = promoteSavedQueuedUser(listOf(history, Bubble("queued_msg_a", "a"),
            Bubble("queued_msg_b", "b"), later), setOf("a", "b"), saved) { it.queue }
        assertEquals(listOf(history, saved, later), result)
        assertEquals("database-user", result.last { it.queue == null }.id)
    }

    @Test fun should_appendSavedBubbleWhenNoPlaceholderRemains() {
        val history = Bubble("old-user")
        val saved = Bubble("database-user")
        assertEquals(listOf(history, saved),
            promoteSavedQueuedUser(listOf(history), setOf("a"), saved) { it.queue })
    }
}
