package io.github.nanomuse.speech

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** 验证教练语音不会访问服务商，并在手动重读时保留本轮策略。 */
class CoachSpeechRoutingTest {
    @Test
    fun `system only speech never evaluates provider resolution`() {
        val entry = SpeechOutputPolicy.SYSTEM_ONLY.resolveProvider<String> {
            error("教练朗读不应查询服务商或凭据")
        }

        assertNull(entry)
    }

    @Test
    fun `ordinary speech preserves the selected provider route`() {
        var resolutionCount = 0
        val entry = SpeechOutputPolicy.FOLLOW_SELECTION.resolveProvider {
            resolutionCount += 1
            "selected voice"
        }

        assertEquals("selected voice", entry)
        assertEquals(1, resolutionCount)
    }

    @Test
    fun `manual replay keeps the coach route for rendered block ids`() {
        val routing = CoachSpeechRouting()
        routing.remember("coach-answer", systemOnly = true)

        assertEquals(SpeechOutputPolicy.SYSTEM_ONLY, routing.policyFor("coach-answer#text-2"))
        assertEquals(SpeechOutputPolicy.FOLLOW_SELECTION, routing.policyFor("ordinary-answer"))
    }

    @Test
    fun `an explicit coach read also tags subsequent manual replay`() {
        val routing = CoachSpeechRouting()

        assertEquals(SpeechOutputPolicy.SYSTEM_ONLY, routing.policyFor("coach-answer", systemOnly = true))
        assertEquals(SpeechOutputPolicy.SYSTEM_ONLY, routing.policyFor("coach-answer"))
        routing.clear()
        assertEquals(SpeechOutputPolicy.FOLLOW_SELECTION, routing.policyFor("coach-answer"))
    }

    @Test
    fun `persisted coach tools are recognized without treating ordinary names as coach`() {
        assertTrue(isCoachToolName("coach"))
        assertTrue(isCoachToolName("coach_review"))
        assertFalse(isCoachToolName("search"))
        assertFalse(isCoachToolName("coaching_reference"))
    }

    @Test
    fun `a cross message selection includes coach messages between ordinary endpoints`() {
        val routing = CoachSpeechRouting()
        routing.remember("coach-answer", systemOnly = true)

        assertEquals(SpeechOutputPolicy.SYSTEM_ONLY, routing.policyForSelection(
            listOf("ordinary-before#1", "ordinary-after#1"),
            listOf("ordinary-before", "coach-answer", "ordinary-after"),
        ))
    }

    @Test
    fun `identified ordinary selections preserve the selected provider`() {
        assertEquals(SpeechOutputPolicy.FOLLOW_SELECTION, CoachSpeechRouting().policyForSelection(
            listOf("ordinary-answer#1"), listOf("ordinary-answer"),
        ))
    }

    @Test
    fun `a selection with no reliable message identity stays on system speech`() {
        assertEquals(SpeechOutputPolicy.SYSTEM_ONLY,
            CoachSpeechRouting().policyForSelection(emptyList(), listOf("ordinary-answer")))
    }
}
