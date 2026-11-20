package io.github.nanomuse.models

import com.openminis.app.data.model.ModelEntry
import com.openminis.app.data.model.normalizeModalityName

/** 模型表单仅修改可见字段，其余能力和推理设置继续沿用当前配置。 */
data class ProviderModelDraft(
    val modelId: String,
    val displayName: String,
    val maxOutputTokensText: String,
    val contextWindowText: String,
    val thinkingEnabled: Boolean,
    val isHidden: Boolean,
    val imageInput: Boolean,
    val pdfInput: Boolean,
    val audioInput: Boolean,
    val videoInput: Boolean,
    val imageOutput: Boolean,
    val audioOutput: Boolean,
    val videoOutput: Boolean,
) {
    /** 校验草稿并生成新记录，不修改原始模型或其引用标识。 */
    fun applyTo(entry: ModelEntry): ModelEntry {
        val base = entry.baseModel
        val trimmedId = modelId.trim()
        require(!entry.isCustom || trimmedId.isNotEmpty()) { "empty_model_id" }
        val overrides = entry.overrides.copy(
            displayName = displayName.trim().takeIf { it.isNotEmpty() && it != base.displayName },
            maxOutputTokens = positiveInteger(maxOutputTokensText),
            contextWindow = positiveInteger(contextWindowText),
            supportsReasoning = thinkingEnabled.takeIf { it != (base.supportsReasoning ?: false) },
            inputModalities = editedModalities(entry.model.inputModalities, base.inputModalities,
                mapOf("image" to imageInput, "pdf" to pdfInput, "audio" to audioInput, "video" to videoInput)),
            outputModalities = editedModalities(entry.model.outputModalities, base.outputModalities,
                mapOf("image" to imageOutput, "audio" to audioOutput, "video" to videoOutput)),
        )
        return entry.copy(
            baseModel = if (entry.isCustom) base.copy(id = trimmedId) else base,
            overrides = overrides,
            isHidden = isHidden,
        )
    }

    companion object {
        /** 从已有配置生成表单初值，空覆盖值继续表示继承供应商默认值。 */
        fun from(entry: ModelEntry): ProviderModelDraft {
            val inputs = entry.model.inputModalities.orEmpty().map { it.normalizeModalityName() }
            val outputs = entry.model.outputModalities.orEmpty().map { it.normalizeModalityName() }
            return ProviderModelDraft(
                modelId = entry.baseModel.id,
                displayName = entry.model.displayName,
                maxOutputTokensText = entry.overrides.maxOutputTokens?.toString().orEmpty(),
                contextWindowText = entry.overrides.contextWindow?.toString().orEmpty(),
                thinkingEnabled = entry.model.supportsReasoning ?: false,
                isHidden = entry.isHidden,
                imageInput = "image" in inputs,
                pdfInput = "pdf" in inputs,
                audioInput = "audio" in inputs,
                videoInput = "video" in inputs,
                imageOutput = "image" in outputs,
                audioOutput = "audio" in outputs,
                videoOutput = "video" in outputs,
            )
        }

        /** 禁止同一供应商中的重复模型ID覆盖已有模型，更新时排除原记录自身。 */
        fun requireUnique(entries: List<ModelEntry>, candidate: ModelEntry, originalId: String? = null) {
            require(candidate.baseModel.id.isNotBlank()) { "empty_model_id" }
            require(entries.none {
                it.id != originalId && it.providerInstanceId == candidate.providerInstanceId &&
                    it.baseModel.id == candidate.baseModel.id
            }) { "duplicate_model_id" }
        }

        /** 保存和重置共用严格快照校验，调用者须在配置锁内读取并提交，拒绝旧表单覆盖新配置。 */
        fun requireCurrent(entries: List<ModelEntry>, expected: ModelEntry): ModelEntry {
            val current = checkNotNull(entries.singleOrNull { it.id == expected.id }) { "model_no_longer_exists" }
            check(current == expected) { "model_changed" }
            return current
        }

        private fun positiveInteger(text: String): Int? {
            if (text.isBlank()) return null
            return requireNotNull(text.trim().toIntOrNull()?.takeIf { it > 0 }) { "invalid_token_limit" }
        }

        private fun editedModalities(
            effective: List<String>?, base: List<String>?, switches: Map<String, Boolean>,
        ): List<String>? {
            val result = modalitiesWithDefaultText(effective).toMutableSet()
            switches.forEach { (modality, enabled) ->
                if (enabled) result.add(modality) else result.remove(modality)
            }
            val inherited = modalitiesWithDefaultText(base)
            return result.toList().takeIf { result != inherited }
        }

        private fun modalitiesWithDefaultText(modalities: List<String>?): Set<String> =
            modalities.orEmpty().map { it.normalizeModalityName() }.toSet().ifEmpty { setOf("text") }
    }
}
