package io.github.nanomuse.models

import com.openminis.app.data.model.LLMModel
import com.openminis.app.data.model.ModelEntry
import com.openminis.app.data.model.ModelOverrides
import com.openminis.app.data.model.ThinkingLevel
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

/** 验证真实模型表单转换保留未展示的能力，并在写入前拒绝无效输入。 */
class ProviderModelDraftTest {
    private fun entry(
        inputs: List<String>? = listOf("text", "image"),
        outputs: List<String>? = listOf("text"),
        overrides: ModelOverrides = ModelOverrides(),
    ) = ModelEntry(
        providerInstanceId = "provider",
        baseModel = LLMModel(
            id = "model-a", displayName = "Original", provider = "Test",
            inputModalities = inputs, outputModalities = outputs,
        ),
        overrides = overrides,
        isCustom = true,
        uuid = "provider/model-a",
    )

    @Test
    fun `rename preserves text and unexposed thinking ceiling`() {
        val original = entry(overrides = ModelOverrides(maxThinkingLevel = ThinkingLevel.HIGH))
        val result = ProviderModelDraft.from(original).copy(displayName = "Renamed").applyTo(original)
        assertEquals(listOf("text", "image"), result.model.inputModalities)
        assertEquals(listOf("text"), result.model.outputModalities)
        assertEquals(ThinkingLevel.HIGH, result.overrides.maxThinkingLevel)
        assertEquals(original.id, result.id)
    }

    @Test
    fun `toggling a capability preserves unknown and hidden modalities`() {
        val original = entry(inputs = listOf("text", "image_input", "sensor"))
        val result = ProviderModelDraft.from(original).copy(imageInput = false, audioInput = true).applyTo(original)
        assertEquals(setOf("text", "sensor", "audio"), result.model.inputModalities?.toSet())
    }

    @Test
    fun `adding capabilities preserves implicit text for null and empty modalities`() {
        listOf<List<String>?>(null, emptyList()).forEach { modalities ->
            val original = entry(inputs = modalities, outputs = modalities)
            val result = ProviderModelDraft.from(original).copy(imageInput = true, audioOutput = true).applyTo(original)
            assertEquals(setOf("text", "image"), result.model.inputModalities?.toSet())
            assertEquals(setOf("text", "audio"), result.model.outputModalities?.toSet())
            assertTrue(result.model.isTextOutput)
        }
    }

    @Test
    fun `unchanged implicit text remains inherited without creating overrides`() {
        listOf<List<String>?>(null, emptyList()).forEach { modalities ->
            val original = entry(inputs = modalities, outputs = modalities)
            val result = ProviderModelDraft.from(original).copy(displayName = "Renamed").applyTo(original)
            assertNull(result.overrides.inputModalities)
            assertNull(result.overrides.outputModalities)
            assertTrue(result.model.isTextOutput)
        }
    }

    @Test
    fun `stale form snapshot rejects refreshed capabilities and newer user settings`() {
        val original = entry()
        val changes = listOf(
            original.copy(baseModel = original.baseModel.copy(inputModalities = listOf("text", "image", "video"))),
            original.copy(baseModel = original.baseModel.copy(contextWindow = 128_000)),
            original.copy(overrides = original.overrides.copy(maxThinkingLevel = ThinkingLevel.HIGH)),
            original.copy(isHidden = true),
            original.copy(userModifiedAt = 100),
        )
        changes.forEach { current ->
            val failure = assertThrows(IllegalStateException::class.java) {
                ProviderModelDraft.requireCurrent(listOf(current), original)
            }
            assertEquals("model_changed", failure.message)
        }
    }

    @Test
    fun `form snapshot accepts unchanged target despite unrelated entries and rejects deletion`() {
        val original = entry()
        val other = original.copy(uuid = "other/model-a", providerInstanceId = "other", isHidden = true)
        assertEquals(original, ProviderModelDraft.requireCurrent(listOf(other, original.copy()), original))
        val failure = assertThrows(IllegalStateException::class.java) {
            ProviderModelDraft.requireCurrent(listOf(other), original)
        }
        assertEquals("model_no_longer_exists", failure.message)
    }

    @Test
    fun `suffix normalization does not create an unnecessary override`() {
        val original = entry(inputs = listOf("TEXT_INPUT", "IMAGE_INPUT"), outputs = listOf("text_output"))
        val result = ProviderModelDraft.from(original).applyTo(original)
        assertNull(result.overrides.inputModalities)
        assertNull(result.overrides.outputModalities)
    }

    @Test
    fun `voice only and video models keep their direction`() {
        listOf(
            listOf("audio") to listOf("text"),
            listOf("text") to listOf("audio"),
            listOf("text", "image") to listOf("video"),
        ).forEach { (inputs, outputs) ->
            val original = entry(inputs, outputs)
            val result = ProviderModelDraft.from(original).copy(displayName = "Renamed").applyTo(original)
            assertEquals(inputs, result.model.inputModalities)
            assertEquals(outputs, result.model.outputModalities)
        }
    }

    @Test
    fun `editing trims the model id and rejects invalid numeric input`() {
        val original = entry()
        val draft = ProviderModelDraft.from(original)
        assertEquals("new-id", draft.copy(modelId = " new-id ").applyTo(original).baseModel.id)
        listOf("0", "-1", "abc", "999999999999999").forEach { invalid ->
            assertThrows(IllegalArgumentException::class.java) {
                draft.copy(contextWindowText = invalid).applyTo(original)
            }
        }
        assertThrows(IllegalArgumentException::class.java) {
            draft.copy(modelId = " ").applyTo(original)
        }
    }

    @Test
    fun `new model collision cannot replace an existing custom model`() {
        val original = entry(overrides = ModelOverrides(contextWindow = 8192))
        assertThrows(IllegalArgumentException::class.java) {
            ProviderModelDraft.requireUnique(listOf(original), original.copy(uuid = "new-uuid"))
        }
        assertEquals(8192, original.overrides.contextWindow)
    }

    @Test
    fun `rename collision is rejected but same model id on another provider is valid`() {
        val original = entry()
        val other = original.copy(uuid = "provider/model-b", baseModel = original.baseModel.copy(id = "model-b"))
        assertThrows(IllegalArgumentException::class.java) {
            ProviderModelDraft.requireUnique(listOf(original, other), original.copy(baseModel = other.baseModel), original.id)
        }
        ProviderModelDraft.requireUnique(listOf(original), original, original.id)
        ProviderModelDraft.requireUnique(listOf(original), original.copy(providerInstanceId = "another", uuid = "new"))
    }
}
