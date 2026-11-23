package io.github.nanomuse.chat

import com.openminis.app.data.model.LLMModel
import com.openminis.app.ui.chat.isMarkdownHeadingLine
import io.github.nanomuse.models.CapacitySource
import io.github.nanomuse.models.ModelCapacity
import io.github.nanomuse.skills.SkillFrontMatter
import java.io.ByteArrayInputStream
import java.io.IOException
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

/** 发布前覆盖上游问题修复中的实际边界，不使用真实模型或用户记录。 */
class UpstreamFixRegressionTest {
    @Test
    fun should_treatCodePrefixesAsText_when_hashIsNotFollowedByWhitespace() {
        listOf("#tag", "#include", "#!/bin/sh", "###tag").forEach {
            assertFalse(it, isMarkdownHeadingLine(it))
        }
    }

    @Test
    fun should_acceptEmptyAndTabbedHeadings_when_hashPrefixIsValid() {
        listOf("#", "##", "## heading", "###\theading").forEach {
            assertTrue(it, isMarkdownHeadingLine(it))
        }
        assertFalse(isMarkdownHeadingLine(""))
    }

    @Test
    fun should_deferStop_when_startHasNotBeenPromoted() {
        val gate = ForegroundServiceGate()
        var sequence = 0L
        var stops = 0
        assertTrue(gate.start { sequence = it; true })
        gate.stop { stops++ }
        assertEquals(0, stops)
        gate.promoted(sequence) { stops++ }
        assertEquals(1, stops)
        gate.promoted(sequence) { stops++ }
        assertEquals(1, stops)
    }

    @Test
    fun should_cancelPendingStop_when_newStartIsAccepted() {
        val gate = ForegroundServiceGate()
        val sequences = mutableListOf<Long>()
        var stops = 0
        gate.start { sequences += it; true }
        gate.stop { stops++ }
        gate.start { sequences += it; true }
        sequences.forEach { gate.promoted(it) { stops++ } }
        assertEquals(0, stops)
        gate.stop { stops++ }
        assertEquals(1, stops)
    }

    @Test
    fun should_waitForNewestPromotion_when_multipleStartsArePending() {
        val gate = ForegroundServiceGate()
        val sequences = mutableListOf<Long>()
        var stops = 0
        repeat(2) { gate.start { sequences += it; true } }
        gate.stop { stops++ }
        gate.promoted(sequences.first()) { stops++ }
        assertEquals(0, stops)
        gate.promoted(sequences.last()) { stops++ }
        assertEquals(1, stops)
    }

    @Test
    fun should_allowImmediateStop_when_systemRejectedStart() {
        val gate = ForegroundServiceGate()
        var stops = 0
        assertFalse(gate.start { false })
        gate.stop { stops++ }
        assertEquals(1, stops)
    }

    @Test
    fun should_rejectOversizedContent_when_sizeWasNotReported() {
        val stream = capped(byteArrayOf(1, 2, 3), 2)
        assertEquals(1, stream.read())
        assertEquals(2, stream.read())
        assertThrows(IOException::class.java) { stream.read() }
        assertNotNull(stream.failure)
    }

    @Test
    fun should_acceptExactLimit_when_sourceEndsAtBoundary() {
        val stream = capped(byteArrayOf(1, 2), 2)
        assertArrayEquals(byteArrayOf(1, 2), stream.readBytes())
        assertNull(stream.failure)
    }

    @Test
    fun should_enforceBulkReadLimit_when_copyUsesBuffer() {
        val stream = capped(ByteArray(20), 10)
        assertThrows(IOException::class.java) { stream.read(ByteArray(20), 0, 20) }
    }

    @Test
    fun should_abortCopy_when_ownerIsCancelled() {
        var active = true
        val stream = CappedInputStream(ByteArrayInputStream(byteArrayOf(1, 2)), 2, { active }) { IOException("limit") }
        assertEquals(1, stream.read())
        active = false
        assertThrows(IOException::class.java) { stream.read() }
    }

    @Test
    fun should_boundRetriesAndRecover_when_endMarkerReturns() {
        val model = "release-regression/model"
        UnfinishedStreams.ended(model)
        assertTrue(UnfinishedStreams.shouldRetry(model, 0))
        assertTrue(UnfinishedStreams.shouldRetry(model, 1))
        assertFalse(UnfinishedStreams.shouldRetry(model, 2))
        assertFalse(UnfinishedStreams.shouldRetry(model, 0))
        UnfinishedStreams.ended(model)
        assertTrue(UnfinishedStreams.shouldRetry(model, 0))
    }

    @Test
    fun should_isolateRetryHistory_when_modelsDiffer() {
        UnfinishedStreams.shouldRetry("release-regression/silent", 2)
        assertTrue(UnfinishedStreams.shouldRetry("release-regression/other", 0))
        UnfinishedStreams.ended("release-regression/silent")
    }

    @Test
    fun should_removeReplayedCall_when_onlyOneResultExists() {
        val input = JSONArray().put(call("a", "item")).put(call("a", "item")).put(output("a", "done"))
        val result = ResponsesCallPairing.normalize(input)
        assertEquals(2, result.length())
        assertEquals(result.getJSONObject(0).getString("call_id"), result.getJSONObject(1).getString("call_id"))
    }

    @Test
    fun should_renameBothIds_when_duplicateCallsEachHaveResults() {
        val input = JSONArray().put(call("a", "item")).put(output("a", "first"))
            .put(call("a", "item")).put(output("a", "second"))
        val result = ResponsesCallPairing.normalize(input)
        assertEquals(4, result.length())
        assertNotEquals(result.getJSONObject(0).getString("id"), result.getJSONObject(2).getString("id"))
        assertNotEquals(result.getJSONObject(0).getString("call_id"), result.getJSONObject(2).getString("call_id"))
        listOf(0, 2).forEach { index ->
            assertEquals(result.getJSONObject(index).getString("call_id"), result.getJSONObject(index + 1).getString("call_id"))
        }
    }

    @Test
    fun should_keepReasoningId_when_toolItemIdCollides() {
        val input = JSONArray().put(JSONObject().put("type", "reasoning").put("id", "item"))
            .put(call("a", "item")).put(output("a", "done"))
        val result = ResponsesCallPairing.normalize(input)
        assertEquals("item", result.getJSONObject(0).getString("id"))
        assertNotEquals("item", result.getJSONObject(1).getString("id"))
    }

    @Test
    fun should_dropExtraResult_when_callAlreadyHasResult() {
        val result = ResponsesCallPairing.normalize(JSONArray().put(call("a", "item"))
            .put(output("a", "first")).put(output("a", "replay")))
        assertEquals(2, result.length())
        assertEquals("first", result.getJSONObject(1).getString("output"))
    }

    @Test
    fun should_useLoadedAndRoutedCapacity_when_providerReportsBoth() {
        val limits = ModelCapacity.fromListing(JSONObject("""{"context_length":131072,"loaded_context_length":8192,"top_provider":{"context_length":4096,"max_completion_tokens":2048}}"""))
        assertEquals(4096, limits.contextWindow)
        assertEquals(2048, limits.maxOutputTokens)
    }

    @Test
    fun should_rejectInvalidLimits_when_outputExceedsContext() {
        val limits = ModelCapacity.fromListing(JSONObject("""{"context_length":4096,"max_output_tokens":8192}"""))
        assertEquals(4096, limits.contextWindow)
        assertNull(limits.maxOutputTokens)
        assertNull(ModelCapacity.fromListing(JSONObject("""{"context_length":8}""")).contextWindow)
    }

    @Test
    fun should_keepUserPriority_when_endpointAlsoProvidesLimit() {
        val model = LLMModel(id = "model", displayName = "Model", provider = "test", contextWindow = 8192,
            isContextWindowFromEndpoint = true)
        assertEquals(CapacitySource.ENDPOINT, ModelCapacity.source(model, null, false))
        assertEquals(CapacitySource.OVERRIDE, ModelCapacity.source(model, 4096, false))
    }

    @Test
    fun should_ignoreNestedDescription_when_readingSkillMetadata() {
        val source = "---\nname: sample\ndescription: |\n  first line\n  second line\nmetadata:\n  description: nested\n  version: '1.0'\n---\nBody\n"
        val parsed = requireNotNull(SkillFrontMatter.parse(source))
        assertEquals("first line\nsecond line", parsed["description"])
        assertEquals("1.0", parsed.nested("metadata", "version"))
        assertEquals(source, parsed.rewrite(mapOf("name" to "sample")))
    }

    @Test
    fun should_preserveUnknownMetadata_when_editingSkillName() {
        val source = "---\nname: old\nx-private:\n  flag: true\ndescription: 'It''s useful'\n---\nBody\n"
        val parsed = requireNotNull(SkillFrontMatter.parse(source))
        assertEquals("It's useful", parsed["description"])
        assertEquals(source.replace("name: old", "name: new"), parsed.rewrite(mapOf("name" to "new")))
    }

    private fun capped(bytes: ByteArray, limit: Long) =
        CappedInputStream(ByteArrayInputStream(bytes), limit, { true }) { IOException("limit") }

    private fun call(id: String, item: String) = JSONObject().put("type", "function_call")
        .put("call_id", id).put("id", item).put("name", "echo").put("arguments", "{}")

    private fun output(id: String, value: String) = JSONObject().put("type", "function_call_output")
        .put("call_id", id).put("output", value)
}
