package io.github.nanomuse.skills

/**
 * SKILL.md开头的元数据。只读顶层字段，缩进的内容属于上一个字段，`metadata`里的`description`不会盖掉技能自己的描述。
 * 支持单双引号、`|`和`>`块、缩进续行。改写时只动指定字段，其余原文（包括不认识的字段）一字不改。
 */
internal class SkillFrontMatter private constructor(
    private val lines: List<String>,
    private val closingLine: Int,
    private val entries: List<Entry>,
    private val lineBreak: String,
) {
    /** 一个顶层字段，[first]到[end]（不含）是它占的行。 */
    private class Entry(val key: String, val value: String, val first: Int, val end: Int, val nested: Map<String, String>)

    /** 顶层字段的值；没有这个字段时为空。 */
    operator fun get(key: String): String? = entries.lastOrNull { it.key == key }?.value

    /** 一层嵌套字段的值，例如`metadata`里的`version`。 */
    fun nested(parent: String, key: String): String? = entries.lastOrNull { it.key == parent }?.nested?.get(key)

    /** 元数据之后的正文，去掉首尾空行。 */
    val body: String get() = lines.drop(closingLine + 1).joinToString("\n").trim('\n')

    /** 换掉给定字段（值没变的保持原写法）和正文，其余原文保留；[body]为空表示正文不变。 */
    fun rewrite(fields: Map<String, String>, body: String? = null): String {
        val header = lines.subList(0, closingLine).toMutableList()
        // 从后往前改，前面的行号不受影响。
        val changed = entries.filter { it.key in fields && it.value != fields[it.key] }.sortedByDescending { it.first }
        for (entry in changed) {
            header.subList(entry.first, entry.end).clear()
            header.add(entry.first, "${entry.key}: ${scalar(fields.getValue(entry.key))}")
        }
        val missing = fields.filterKeys { key -> entries.none { it.key == key } }
        header.addAll(1, missing.map { (key, value) -> "$key: ${scalar(value)}" })
        val rest = if (body == null || body == this.body) lines.drop(closingLine + 1) else listOf("") + body.lines()
        return (header + lines[closingLine] + rest).joinToString(lineBreak)
    }

    companion object {
        private const val FENCE = "---"
        private const val BYTE_ORDER_MARK = '﻿'

        /** 没有成对的`---`时返回空。 */
        fun parse(text: String): SkillFrontMatter? {
            val lines = text.trimStart(BYTE_ORDER_MARK).trimStart().lines()
            if (lines.firstOrNull()?.startsWith(FENCE) != true) return null
            val closing = (1 until lines.size).firstOrNull { lines[it].trimEnd() == FENCE } ?: return null
            val lineBreak = if (text.contains("\r\n")) "\r\n" else "\n"
            return SkillFrontMatter(lines, closing, readEntries(lines, closing), lineBreak)
        }

        /** 生成一份新的SKILL.md。 */
        fun compose(fields: Map<String, String>, body: String): String = buildString {
            append(FENCE).append('\n')
            for ((key, value) in fields) append(key).append(": ").append(scalar(value)).append('\n')
            append(FENCE).append('\n').append(body)
        }

        private fun readEntries(lines: List<String>, closing: Int): List<Entry> {
            val entries = mutableListOf<Entry>()
            var index = 1
            while (index < closing) {
                val line = lines[index]
                val colon = line.indexOf(':')
                if (colon <= 0 || line[0].isWhitespace() || line[0] == '#') {
                    index += 1
                    continue
                }
                var end = index + 1
                while (end < closing && (lines[end].isBlank() || lines[end][0].isWhitespace())) end += 1
                val inner = lines.subList(index + 1, end)
                val raw = line.substring(colon + 1).trim()
                val isMapping = raw.isEmpty() && isStructure(inner)
                entries += Entry(
                    key = line.substring(0, colon).trim().lowercase(),
                    value = if (isMapping) "" else readScalar(raw, inner),
                    first = index,
                    end = end,
                    nested = if (isMapping) readMapping(inner) else emptyMap(),
                )
                index = end
            }
            return entries
        }

        /** 缩进的第一行是`键:`或列表时，它是嵌套结构，不是换行书写的文字。 */
        private fun isStructure(inner: List<String>): Boolean {
            val first = inner.firstOrNull { it.isNotBlank() }?.trim() ?: return false
            if (first.startsWith("- ") || first.startsWith("#")) return true
            val colon = first.indexOf(':')
            return colon > 0 && (colon == first.lastIndex || first[colon + 1].isWhitespace()) &&
                first.substring(0, colon).none { it.isWhitespace() }
        }

        private fun readMapping(inner: List<String>): Map<String, String> {
            val indent = inner.filter { it.isNotBlank() }.minOfOrNull(::indentOf) ?: return emptyMap()
            return inner.filter { it.isNotBlank() && indentOf(it) == indent && it.indexOf(':') > 0 }.associate { line ->
                val colon = line.indexOf(':')
                line.substring(0, colon).trim().lowercase() to readScalar(line.substring(colon + 1).trim(), emptyList())
            }
        }

        private fun readScalar(raw: String, inner: List<String>): String = when {
            isBlockMarker(raw) -> readBlock(isFolded = raw[0] == '>', inner)
            raw.startsWith('"') -> readQuoted(raw, inner, '"')
            raw.startsWith('\'') -> readQuoted(raw, inner, '\'')
            else -> (listOf(raw) + inner.map { it.trim() }).filter { it.isNotEmpty() }.joinToString(" ")
        }

        /** `|`或`>`，后面可以跟截断标记和缩进数字。 */
        private fun isBlockMarker(raw: String): Boolean = raw.isNotEmpty() && raw[0] in "|>" &&
            raw.substring(1).substringBefore(" #").trim().all { it in "+-0123456789" }

        private fun readBlock(isFolded: Boolean, inner: List<String>): String {
            val indent = inner.filter { it.isNotBlank() }.minOfOrNull(::indentOf) ?: 0
            val text = inner.map { it.drop(minOf(indent, indentOf(it))).trimEnd() }
            if (!isFolded) return text.joinToString("\n").trim('\n')
            // 折叠块：相邻的行接成一行，空行才换行。
            return text.joinToString("\n").split("\n\n").joinToString("\n") { part ->
                part.lines().map { it.trim() }.filter { it.isNotEmpty() }.joinToString(" ")
            }.trim()
        }

        private fun readQuoted(raw: String, inner: List<String>, quote: Char): String {
            val source = (listOf(raw) + inner.map { it.trim() }).joinToString(" ")
            val out = StringBuilder()
            var index = 1
            while (index < source.length) {
                val char = source[index]
                if (char == quote) {
                    // 单引号里连写两个表示一个单引号。
                    if (quote != '\'' || source.getOrNull(index + 1) != '\'') return out.toString()
                    out.append('\'')
                    index += 2
                } else if (char == '\\' && quote == '"') {
                    index = readEscape(source, index + 1, out)
                } else {
                    out.append(char)
                    index += 1
                }
            }
            // 引号没有收尾，按原样显示，不猜测。
            return raw
        }

        private fun readEscape(source: String, index: Int, out: StringBuilder): Int {
            when (val char = source.getOrNull(index) ?: return index) {
                'n' -> out.append('\n')
                't' -> out.append('\t')
                'r' -> out.append('\r')
                'u' -> {
                    val code = source.drop(index + 1).take(4).takeIf { it.length == 4 }?.toIntOrNull(16)
                    if (code == null) return index + 1
                    out.append(code.toChar())
                    return index + 5
                }
                else -> out.append(char)
            }
            return index + 1
        }

        private fun indentOf(line: String): Int = line.length - line.trimStart().length

        /** 能直接写的保持原样，其余用双引号，读回来得到同样的文字。 */
        private fun scalar(value: String): String {
            val isPlain = value.isNotEmpty() && value == value.trim() &&
                value[0] !in "\"'|>&*!%@`{}[],#?-:" && value.none { it == '\n' || it == '\r' || it == '\t' } &&
                !value.contains(": ") && !value.contains(" #") && !value.endsWith(":")
            if (isPlain) return value
            return buildString {
                append('"')
                for (char in value) when (char) {
                    '"' -> append("\\\"")
                    '\\' -> append("\\\\")
                    '\n' -> append("\\n")
                    '\r' -> append("\\r")
                    '\t' -> append("\\t")
                    else -> append(char)
                }
                append('"')
            }
        }
    }
}
