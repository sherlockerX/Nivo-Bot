package io.github.nanomuse.skills

/** 系统提示里技能描述的总预算。描述决定模型会不会选用这个技能，尽量给全，放不下时才一起缩短。 */
internal object SkillPromptBudget {
    /** 所有技能描述合计的字符数。 */
    const val MAX_TOTAL_CHARS = 8_000

    /** 单个描述的上限，与Agent Skills规范对描述长度的规定一致。 */
    const val MAX_ONE_CHARS = 1_024

    /** 按原顺序返回能放进预算的描述：短的保持完整，长的缩到同一个上限。 */
    fun fit(descriptions: List<String>, total: Int = MAX_TOTAL_CHARS): List<String> {
        val limit = sharedLimit(descriptions.map { minOf(it.length, MAX_ONE_CHARS) }, total)
        return descriptions.map { if (it.length <= limit) it else cut(it, limit) }
    }

    /** 从短到长依次分配，用不完的额度留给更长的描述。 */
    private fun sharedLimit(lengths: List<Int>, total: Int): Int {
        var remaining = total
        val sorted = lengths.sorted()
        sorted.forEachIndexed { index, length ->
            val share = remaining / (sorted.size - index)
            if (length > share) return share
            remaining -= length
        }
        return MAX_ONE_CHARS
    }

    /** 不在代理对中间截断，表情等字符不会变成乱码。 */
    private fun cut(text: String, limit: Int): String {
        val end = if (limit > 0 && text[limit - 1].isHighSurrogate()) limit - 1 else limit
        return text.substring(0, end).trimEnd() + "…"
    }
}
