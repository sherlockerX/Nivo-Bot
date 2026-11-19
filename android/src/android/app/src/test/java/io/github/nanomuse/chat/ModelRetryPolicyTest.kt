package io.github.nanomuse.chat

import com.openminis.app.data.model.LLMError
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.IOException
import java.net.SocketTimeoutException

/** 供应商一次失败先在同一模型上重试，请求本身有错时才立刻放弃。 */
class ModelRetryPolicyTest {
    @Test fun should_retryAtLeastFiveTimes_beforeGivingUp() {
        assertTrue(ModelRetryPolicy.DELAYS_SEC.size >= 5)
        assertEquals(6, ModelRetryPolicy.DELAYS_SEC.size)
    }

    @Test fun should_retry_when_providerFailsForThisCallOnly() {
        listOf(
            LLMError.NetworkError(SocketTimeoutException("timeout")),
            LLMError.TransientError("[502] bad gateway"),
            LLMError.RateLimited(),
            LLMError.DecodingError(IllegalStateException("stream cut")),
            LLMError.Unknown(null),
            LLMError.ProviderError("[500] upstream error"),
            LLMError.ProviderError("[429] too many requests"),
            LLMError.ProviderError("[408] request timeout"),
            LLMError.ProviderError("[server_error] The server had an error"),
            LLMError.ProviderError("upstream stream closed"),
            IOException("connection reset"),
        ).forEach { assertTrue(it.toString(), ModelRetryPolicy.shouldRetry(it)) }
    }

    @Test fun should_notRetry_when_retryCannotChangeTheAnswer() {
        listOf(
            LLMError.Cancelled(),
            LLMError.InvalidApiKey(),
            LLMError.ProviderError("[400] This model's maximum context length is 128000 tokens"),
            LLMError.ProviderError("HTTP 404: not found"),
            LLMError.ProviderError("[422] invalid tool schema"),
            LLMError.ProviderError("[503] model_not_found"),
            LLMError.ProviderError("DataInspectionFailed: inappropriate content"),
            IllegalArgumentException("bug"),
        ).forEach { assertFalse(it.toString(), ModelRetryPolicy.shouldRetry(it)) }
    }
}
