package io.github.nanomuse.account

/** nanoMuse: 按会话清理数据及归属，使失败后的剩余记录能够继续处理。 */
internal suspend fun deleteOwnedChats(
    sessionIds: List<String>,
    deleteChat: suspend (String) -> Unit,
    removeOwner: suspend (String) -> Unit,
) {
    for (sessionId in sessionIds) {
        // 删除异常直接终止；归属保留到数据和附件全部清理成功，供原迁移重试。
        deleteChat(sessionId)
        removeOwner(sessionId)
    }
}
