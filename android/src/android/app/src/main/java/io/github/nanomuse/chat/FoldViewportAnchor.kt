package io.github.nanomuse.chat

/** 将稳定行身份映射到当前列表位置，容纳流式插入和额外提示行。 */
object FoldViewportAnchor {
    /** 下一次测量直接使用的列表位置，不需要先跳到零偏移。 */
    data class Request(val index: Int, val scrollOffset: Int)

    /** 使用最新展示行和提示行数量，保持固定高度标题的逻辑偏移。 */
    fun requestFor(key: String, rows: List<String>, extraItems: Int, itemOffset: Int): Request? {
        if (extraItems < 0) return null
        val index = rows.indexOf(key)
        return if (index < 0) null else Request(index + extraItems, -itemOffset)
    }

}
