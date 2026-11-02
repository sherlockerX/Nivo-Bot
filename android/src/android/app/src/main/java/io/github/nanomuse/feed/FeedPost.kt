package io.github.nanomuse.feed

import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * One card on the Coach tab. On disk it is `minis-global/nanomuse/feed/YYYY-MM-DD/NN.md`: a YAML-ish
 * front matter (title, type, emoji, source, created, liked, track, level, prompt, unit) and a Markdown body. Plain files on
 * purpose — the agent can read them back, a backup carries them, and nothing is lost if the app
 * forgets about them.
 */
data class FeedPost(
    val day: String,          // YYYY-MM-DD
    val index: Int,           // NN within the day
    val title: String,
    val type: String,         // Mosaic: theory | practice | challenge | review | action | weekly (FeedFlow.TYPES)
    val emoji: String,
    val body: String,
    val source: List<String>,
    val createdAt: Long,
    val liked: Boolean,
    val file: File,
    // Mosaic: a practice card names the ability it trains, its level and the question to answer.
    val track: String? = null,
    val level: Int = 0,
    val prompt: String = "",
    /** Mosaic: the unit of the ability's course the card belongs to, as the skill numbers it ("1.2 …"). */
    val unit: String = "",
) {
    val id: String get() = "$day/${"%02d".format(Locale.ROOT, index)}"

    fun serialize(): String = buildString {
        appendLine("---")
        appendLine("title: ${escape(title)}")
        appendLine("type: $type")
        if (emoji.isNotBlank()) appendLine("emoji: $emoji")
        if (source.isNotEmpty()) appendLine("source: ${source.joinToString("; ") { escape(it) }}")
        appendLine("created: ${ISO.format(Date(createdAt))}")
        if (liked) appendLine("liked: true")
        if (track != null) appendLine("track: $track")
        if (level > 0) appendLine("level: $level")
        if (prompt.isNotBlank()) appendLine("prompt: ${escape(prompt)}")
        if (unit.isNotBlank()) appendLine("unit: ${escape(unit)}")
        appendLine("---")
        appendLine()
        append(body.trimEnd())
        appendLine()
    }

    companion object {
        private val ISO = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ssZ", Locale.US)
        private val FILE_NAME = Regex("^(\\d{2})\\.md$")
        private val DAY_NAME = Regex("^\\d{4}-\\d{2}-\\d{2}$")

        fun isDayDir(f: File): Boolean = f.isDirectory && DAY_NAME.matches(f.name)

        fun parse(file: File): FeedPost? {
            val day = file.parentFile?.name?.takeIf { DAY_NAME.matches(it) } ?: return null
            val index = FILE_NAME.find(file.name)?.groupValues?.get(1)?.toIntOrNull() ?: return null
            val text = runCatching { file.readText() }.getOrNull() ?: return null
            val (meta, body) = splitFrontMatter(text)
            val created = meta["created"]?.let { runCatching { ISO.parse(it)?.time }.getOrNull() } ?: file.lastModified()
            return FeedPost(
                day = day,
                index = index,
                title = meta["title"]?.let(::unescape).orEmpty().ifBlank { body.lineSequence().firstOrNull()?.trim('#', ' ').orEmpty() },
                type = meta["type"].orEmpty().ifBlank { "note" },
                emoji = meta["emoji"].orEmpty(),
                body = body.trim(),
                source = meta["source"]?.split(";")?.map { unescape(it.trim()) }?.filter { it.isNotEmpty() }.orEmpty(),
                createdAt = created,
                liked = meta["liked"] == "true",
                file = file,
                track = meta["track"]?.trim()?.takeIf { it.isNotEmpty() },
                level = meta["level"]?.trim()?.toIntOrNull() ?: 0,
                prompt = meta["prompt"]?.let(::unescape).orEmpty(),
                unit = meta["unit"]?.let(::unescape).orEmpty(),
            )
        }

        private fun splitFrontMatter(text: String): Pair<Map<String, String>, String> {
            val lines = text.lines()
            if (lines.firstOrNull()?.trim() != "---") return emptyMap<String, String>() to text
            val end = lines.drop(1).indexOfFirst { it.trim() == "---" }
            if (end < 0) return emptyMap<String, String>() to text
            val meta = lines.subList(1, end + 1).mapNotNull { line ->
                val i = line.indexOf(':')
                if (i <= 0) null else line.substring(0, i).trim() to line.substring(i + 1).trim()
            }.toMap()
            val body = lines.drop(end + 2).joinToString("\n")
            return meta to body
        }

        private fun escape(s: String): String = s.replace("\n", " ").replace(";", "，").trim()
        private fun unescape(s: String): String = s.trim().removeSurrounding("\"")
    }
}
