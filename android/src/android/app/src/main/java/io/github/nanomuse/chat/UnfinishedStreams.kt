package io.github.nanomuse.chat

/**
 * 连接正常关闭、却没有任何结束标记的回复。
 *
 * 本轮工具要等流结束才执行，所以在这里重试不会重复执行工具。有的中转从不发送结束标记，
 * 重试也一样；同一模型把次数用完仍然如此，就记下来，之后直接交给“可能不完整”的提示和手动继续。
 */
object UnfinishedStreams {
    /** 每一步最多为这种情况重试的次数；与网络失败的重试共用等待时间。 */
    const val MAX_RETRIES = 2

    private val silentModels = mutableSetOf<String>()

    /** 这次没有结束标记的流是否值得重试，[attempt]是本步已经重试过的次数。 */
    @Synchronized
    fun shouldRetry(model: String, attempt: Int): Boolean {
        if (model in silentModels) return false
        if (attempt < MAX_RETRIES) return true
        silentModels += model
        return false
    }

    /** 收到结束标记，说明这个模型会发送，之后的缺失重新按中断处理。 */
    @Synchronized
    fun ended(model: String) {
        silentModels -= model
    }
}
