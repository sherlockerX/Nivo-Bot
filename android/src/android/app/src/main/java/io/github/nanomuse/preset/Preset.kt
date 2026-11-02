package io.github.nanomuse.preset

import android.content.Context
import com.openminis.app.agent.SoulMDParser
import com.openminis.app.agent.SoulMetadata
import com.openminis.app.agent.SoulStore
import com.openminis.app.data.repository.SkillRepository
import io.github.nanomuse.sysfiles.SystemFiles
import java.io.File

/**
 * The personal build's starting state: the agent's files about its owner and the skills it
 * starts with, shipped under `assets/preset/`. Nothing here overwrites what the owner or the
 * agent has written: a file is seeded once, and only when it is missing or blank then, so one the
 * owner cleared later stays clear; a skill is installed once, so one the owner deleted stays
 * deleted. The persona itself is `SoulStore.DEFAULT_CONTENT`.
 */
object Preset {
    /** Before `SoulStore.ensureExists`: renames a soul left from nanoMuse, seeds USER / GLOBAL / feed preferences. */
    fun ensureFiles(context: Context) {
        renameSoul(context)
        retireFeedSteer(context)
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val seeded = prefs.getStringSet(KEY_SEEDED_FILES, emptySet()).orEmpty()
        val files = listOf(
            "preset/memory/USER.md" to SystemFiles.USER.file(context),
            "preset/memory/GLOBAL.md" to SystemFiles.MEMORY.file(context),
            "preset/feed-preferences.md" to SystemFiles.FEED.file(context),
        ).filter { (asset, _) -> asset !in seeded }
        if (files.isEmpty()) return
        files.forEach { (asset, target) -> seed(context, asset, target) }
        prefs.edit().putStringSet(KEY_SEEDED_FILES, seeded + files.map { it.first }).apply()
    }

    /**
     * Installs each skill under `assets/preset/skills/<id>/SKILL.md` once, as an ordinary skill the owner
     * can edit or delete. Mosaic: an installed one the owner never touched is brought up to a newer version.
     */
    fun installSkills(context: Context, skills: SkillRepository) {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val seeded = prefs.getStringSet(KEY_SEEDED_SKILLS, emptySet()).orEmpty()
        val added = mutableSetOf<String>()
        for (dir in context.assets.list(SKILLS).orEmpty()) {
            val text = runCatching {
                context.assets.open("$SKILLS/$dir/SKILL.md").bufferedReader().use { it.readText() }
            }.getOrNull() ?: continue
            val (meta, body) = frontMatter(text) ?: continue
            val name = meta["name"] ?: continue
            if (dir in seeded) {
                val replaceSince = upgrade(context, skills, dir, text, meta["version"])
                if (skills.skills.value.any { it.id == dir }) copyExtras(context, dir, replaceSince)
                continue
            }
            if (skills.skills.value.none { it.id == dir }) {
                skills.add(
                    name = name,
                    description = meta["description"].orEmpty(),
                    body = body,
                    version = meta["version"] ?: "1.0.0",
                    // Not BUNDLED: those rows outlive their SKILL.md, since only skill-creator is ever reinstalled.
                    source = SkillRepository.ImportSource.FILE,
                )?.let { prefs.edit().putLong(KEY_SKILL_AT + dir, it.updatedAt).apply() }
            }
            if (skills.skills.value.any { it.id == dir }) copyExtras(context, dir)
            added += dir
        }
        if (added.isNotEmpty()) prefs.edit().putStringSet(KEY_SEEDED_SKILLS, seeded + added).apply()
    }

    /**
     * Mosaic: a preset skill the owner never edited follows a newer version shipped with the app (the
     * coach's courses grow this way); one they or the agent edited, or deleted, stays as they left it.
     * Never edited: neither its row nor its SKILL.md changed after this installer last wrote them.
     * Returns when the installer had last written it, once it upgraded; null when nothing changed.
     */
    private fun upgrade(context: Context, skills: SkillRepository, dir: String, text: String, version: String?): Long? {
        val installed = skills.skills.value.firstOrNull { it.id == dir } ?: return null
        if (version == null || compareVersions(version, installed.version) <= 0) return null
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val wroteAt = prefs.getLong(KEY_SKILL_AT + dir, installed.installedAt)
        val file = File(context.filesDir, "minis-global/skills/$dir/SKILL.md")
        if (installed.updatedAt - wroteAt > 1000 || file.lastModified() - wroteAt > 2000) return null
        val upgraded = skills.importFromContent(text) ?: return null
        prefs.edit().putLong(KEY_SKILL_AT + dir, upgraded.updatedAt).apply()
        return wroteAt
    }

    /**
     * Mosaic: the files a preset skill ships besides SKILL.md (a course's `books/` cards). A missing file
     * is added; one already there stays, unless [replaceUntouchedSince] is given and the file has not
     * changed since then (the upgrade of a skill nobody edited). FRAMEWORK.md and ADJUSTMENTS.md are the
     * person's and never ship.
     */
    private fun copyExtras(context: Context, dir: String, replaceUntouchedSince: Long? = null) {
        fun copy(asset: String, target: File) {
            val children = context.assets.list(asset).orEmpty()
            if (children.isNotEmpty()) {
                children.forEach { copy("$asset/$it", File(target, it)) }
                return
            }
            if (target.exists() && (replaceUntouchedSince == null || target.lastModified() - replaceUntouchedSince > 2000)) return
            target.parentFile?.mkdirs()
            runCatching { context.assets.open(asset).use { input -> target.outputStream().use { input.copyTo(it) } } }
        }
        val root = File(context.filesDir, "minis-global/skills/$dir")
        context.assets.list("$SKILLS/$dir").orEmpty().filter { it != "SKILL.md" }.forEach { copy("$SKILLS/$dir/$it", File(root, it)) }
    }

    /**
     * Mosaic: the feed became the coach. A steering file still exactly as first seeded (the old
     * news-feed sentence) gives way to the coach's; one the owner edited stays theirs.
     */
    private fun retireFeedSteer(context: Context) {
        val file = SystemFiles.FEED.file(context)
        if (!file.exists()) return
        val digest = java.security.MessageDigest.getInstance("SHA-256").digest(file.readBytes()).joinToString("") { "%02x".format(it) }
        if (digest != OLD_FEED_STEER_SHA256) return
        file.writeText(context.assets.open("preset/feed-preferences.md").bufferedReader().use { it.readText() })
    }

    /** "2.0.0" against "1.0.0", part by part; a missing or odd part counts as 0. */
    private fun compareVersions(a: String, b: String): Int {
        val x = a.split('.').map { it.trim().toIntOrNull() ?: 0 }
        val y = b.split('.').map { it.trim().toIntOrNull() ?: 0 }
        for (i in 0 until maxOf(x.size, y.size)) {
            val d = x.getOrElse(i) { 0 } - y.getOrElse(i) { 0 }
            if (d != 0) return d
        }
        return 0
    }

    private fun seed(context: Context, asset: String, target: File) {
        if (target.exists() && target.readText().isNotBlank()) return
        val text = context.assets.open(asset).bufferedReader().use { it.readText() }
        target.parentFile?.mkdirs()
        target.writeText(text)
    }

    /**
     * An install from before the rename has a SOUL.md named "nanoMuse". Untouched, it becomes
     * the new persona; edited, only the name changes and the owner's text stays.
     */
    private fun renameSoul(context: Context) {
        val file = SoulStore.fileLocation(context)
        if (!file.exists()) return
        val soul = SoulMDParser.parse(file.readText())
        if (soul.metadata.name != OLD_NAME) return
        file.writeText(
            if (OLD_DEFAULT_MARK in soul.body) SoulStore.DEFAULT_CONTENT
            else SoulMDParser.serialize(soul.copy(metadata = soul.metadata.copy(name = SoulMetadata.DEFAULT.name))),
        )
    }

    /** `name` / `description` / `version` from a SKILL.md front matter (one line each), and the body after it. */
    private fun frontMatter(text: String): Pair<Map<String, String>, String>? {
        val lines = text.replace("\r\n", "\n").lines()
        if (lines.firstOrNull()?.trim() != "---") return null
        val end = lines.drop(1).indexOfFirst { it.trim() == "---" }.takeIf { it >= 0 }?.plus(1) ?: return null
        val meta = lines.subList(1, end).mapNotNull { line ->
            val key = line.substringBefore(':', "").trim()
            if (key.isEmpty()) null else key to line.substringAfter(':').trim().trim('"')
        }.toMap()
        return meta to lines.drop(end + 1).joinToString("\n").trim()
    }

    private const val SKILLS = "preset/skills"
    private const val PREFS = "nm_mosaic"
    private const val KEY_SEEDED_SKILLS = "preset_skills"
    private const val KEY_SEEDED_FILES = "preset_files"
    private const val KEY_SKILL_AT = "preset_skill_at:" // Mosaic: when this installer last wrote a preset skill
    /** Mosaic: the news-feed steering file the previous builds seeded. */
    private const val OLD_FEED_STEER_SHA256 = "abdb09a6f03c885b9e7b743cf181ddad3f8678cd285101b2ebe92f83d586ac5c"
    private const val OLD_NAME = "nanoMuse"
    private const val OLD_DEFAULT_MARK = "**Don't perform"
}
