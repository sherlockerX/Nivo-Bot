package io.github.nanomuse.chat

import com.openminis.app.data.model.LLMError
import io.github.nanomuse.cloud.RelayRefusal

/**
 * 模型请求失败后是否在同一模型上重试。
 *
 * 供应商一次断流、限流或返回错误，不代表服务失效，所以默认重试；只有重试也不会成功的错误
 * 才立刻交给备用模型或报错：用户取消、密钥无效、内容审核拒绝、模型不存在，以及表示请求本身
 * 有问题的4xx。聊天的每一步（包括工具调用之间的后续步骤）都走同一个判定。
 */
object ModelRetryPolicy {
    /** 每次重试前等待的秒数：共重试6次、约50秒，仍失败才切换备用模型或提示错误。 */
    val DELAYS_SEC = intArrayOf(1, 2, 4, 8, 15, 20)

    /** 请求本身有错时重试也没用；408、409、425和429是临时状态，可以重试。 */
    private val RETRYABLE_CLIENT_CODES = setOf(408, 409, 425, 429)

    /** 读取供应商错误开头的HTTP状态码，形如 "[400] ..." 或 "HTTP 400: ..."。 */
    private val STATUS = Regex("""^(?:\[(\d{3})]|HTTP (\d{3})\b)""")

    /** 这次失败是否值得在同一模型上再试一次。 */
    fun shouldRetry(error: Throwable): Boolean = when (error) {
        is LLMError.Cancelled, is LLMError.InvalidApiKey -> false
        is LLMError.ProviderError -> !isPermanent(error.detail)
        // 网络中断、5xx、限流、流被截断或解析失败、未知错误
        is LLMError -> true
        is java.io.IOException -> true
        else -> false
    }

    /** 供应商错误里重试也不会改变结果的那些。 */
    internal fun isPermanent(detail: String): Boolean {
        if (RelayRefusal.contentCheck(detail)) return true
        if (detail.contains("model_not_found") || detail.contains("no_available_providers")) return true
        val match = STATUS.find(detail.trim()) ?: return false
        val status = (match.groupValues[1].ifEmpty { match.groupValues[2] }).toInt()
        return status in 400..499 && status !in RETRYABLE_CLIENT_CODES
    }
}
