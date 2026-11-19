package io.github.nanomuse.chat

/** 将已提交批次替换为真实落盘泡泡，保留历史和提交期间新加入的排队条目。 */
fun <T> promoteSavedQueuedUser(messages: List<T>, queuedIds: Set<String>, savedUser: T,
    queuedId: (T) -> String?): List<T> {
    val firstIndex = messages.indexOfFirst { queuedId(it) in queuedIds }
    if (firstIndex < 0) return messages + savedUser
    val retained = messages.filterNot { queuedId(it) in queuedIds }.toMutableList()
    retained.add(firstIndex, savedUser)
    return retained
}
