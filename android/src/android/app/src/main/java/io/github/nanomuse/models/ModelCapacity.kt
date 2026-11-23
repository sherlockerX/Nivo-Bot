package io.github.nanomuse.models

import androidx.annotation.StringRes
import com.openminis.app.R
import com.openminis.app.data.model.LLMModel
import org.json.JSONObject

/** 上下文容量来自哪里；排在前面的优先。 */
enum class CapacitySource(@StringRes val label: Int) {
    OVERRIDE(R.string.nm_capacity_override),
    ENDPOINT(R.string.nm_capacity_endpoint),
    CATALOG(R.string.nm_capacity_catalog),
    ESTIMATE(R.string.nm_capacity_estimate),
}

/** 当前端点在模型列表里报告的容量；没有报告的为空。 */
class EndpointCapacity(val contextWindow: Int?, val maxOutputTokens: Int?)

/** 模型容量的读取和来源判断。 */
object ModelCapacity {
    /** 同一模型在不同服务上的上限不同，这些字段是服务自己报告的值，先列出正在使用的那一个。 */
    private val CONTEXT_FIELDS = listOf(
        "loaded_context_length", "context_length", "context_window", "max_context_length", "max_model_len",
    )
    private val OUTPUT_FIELDS = listOf("max_completion_tokens", "max_output_tokens")

    /** 小于这个值的不是可用的上下文长度，多半是占位。 */
    private const val MIN_CONTEXT = 512

    /** 从`/v1/models`的一项读取容量；`top_provider`是聚合服务实际路由到的上限，与总上限取较小值。 */
    fun fromListing(item: JSONObject): EndpointCapacity {
        val routed = item.optJSONObject("top_provider")
        val context = listOfNotNull(first(item, CONTEXT_FIELDS), routed?.let { first(it, CONTEXT_FIELDS) }).minOrNull()
        val output = listOfNotNull(first(item, OUTPUT_FIELDS), routed?.let { first(it, OUTPUT_FIELDS) }).minOrNull()
        return EndpointCapacity(
            contextWindow = context?.takeIf { it >= MIN_CONTEXT },
            maxOutputTokens = output?.takeIf { it > 0 && (context == null || it <= context) },
        )
    }

    /** [override]是用户填写的上下文长度，没填为空；用户自己添加的模型，基础值也是用户填写的。 */
    fun source(base: LLMModel, override: Int?, isCustom: Boolean): CapacitySource = when {
        override != null && override > 0 -> CapacitySource.OVERRIDE
        (base.contextWindow ?: 0) <= 0 -> CapacitySource.ESTIMATE
        base.isContextWindowFromEndpoint -> CapacitySource.ENDPOINT
        isCustom -> CapacitySource.OVERRIDE
        else -> CapacitySource.CATALOG
    }

    private fun first(item: JSONObject, fields: List<String>): Int? =
        fields.firstNotNullOfOrNull { field -> item.optInt(field, 0).takeIf { it > 0 } }
}
