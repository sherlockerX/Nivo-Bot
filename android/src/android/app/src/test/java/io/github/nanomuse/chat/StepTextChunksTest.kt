package io.github.nanomuse.chat

import org.junit.Assert.*
import org.junit.Test

/** 过程分片必须有界、无损，并保持已完成片段的边界稳定。 */
class StepTextChunksTest {
    @Test fun should_boundLayoutWork_when_reasoningIsLong() {
        val content = "检查长思考记录。".repeat(4000)
        val chunks = stepTextChunks(content)
        assertTrue(chunks.size > 1)
        assertTrue(chunks.all { it.length <= MAX_STEP_TEXT_CHARS })
        assertEquals(content, chunks.joinToString(""))
    }

    @Test fun should_preserveSurrogatePairs_when_emojiCrossesBoundary() {
        val content = "文".repeat(MAX_STEP_TEXT_CHARS - 1) + "🐛" + "字".repeat(MAX_STEP_TEXT_CHARS)
        val chunks = stepTextChunks(content)
        assertEquals(content, chunks.joinToString(""))
        assertTrue(chunks.none { it.last().isHighSurrogate() || it.first().isLowSurrogate() })
    }

    @Test fun should_keepCompletedChunks_when_streamAppendsText() {
        val content = "检查行边界\n".repeat(600)
        val before = stepTextChunks(content)
        val after = stepTextChunks(content + "后续思考".repeat(400))
        assertEquals(before.dropLast(1), after.take(before.size - 1))
    }

    @Test fun should_ignoreEmptyBody_when_noReadableText() {
        assertTrue(stepTextChunks("\n  ").isEmpty())
        assertEquals(listOf("短思考"), stepTextChunks("短思考"))
    }
}
