package io.github.nanomuse.chat

import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import kotlin.coroutines.coroutineContext

/** 将结果绑定到内容、所有者和配色，切换时不显示旧结果。 */
data class PreparedPresentation<K, V>(val key: K, val value: V) {
    /** 只有当前请求仍匹配时才公开结果。 */
    fun forKey(currentKey: K): V? = value.takeIf { key == currentKey }
}

/** 在后台准备完整呈现数据，取消后不发布结果。 */
suspend fun <K, V> preparePresentation(
    key: K,
    dispatcher: CoroutineDispatcher = Dispatchers.Default,
    prepare: () -> V,
): PreparedPresentation<K, V> = withContext(dispatcher) {
    val value = prepare()
    coroutineContext.ensureActive()
    PreparedPresentation(key, value)
}
