package io.github.nanomuse.feed

import android.content.Context
import com.openminis.app.R
import com.openminis.app.logging.AppLogger
import io.github.nanomuse.sandbox.FeedSandboxScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * The feed on disk: `minis-global/nanomuse/feed/<day>/<NN>.md` posts and the one-paragraph
 * `feed-preferences.md` that steers them. Lives for the process; every write refreshes [posts].
 */
object FeedStore {
    private const val TAG = "Feed"
    private const val MAX_POSTS_PER_DAY = 12
    /** Mosaic: the calendar is the training record, so days are kept longer than the feed kept them (30). */
    const val KEEP_DAYS = 90
    /** File names are two digits, and a number is never handed out twice in a day (see [append]). */
    private const val MAX_INDEX = 99

    private lateinit var root: File
    private lateinit var prefsFile: File
    private lateinit var appContext: Context

    private val _posts = MutableStateFlow<List<FeedPost>>(emptyList())
    /** Newest day first; inside a day the newest batch first, each batch in the model's order. */
    val posts: StateFlow<List<FeedPost>> = _posts

    private val _preferences = MutableStateFlow("")
    val preferences: StateFlow<String> = _preferences

    fun init(context: Context) {
        appContext = context.applicationContext
        val base = File(context.filesDir, "minis-global/nanomuse")
        root = File(base, "feed").apply { mkdirs() }
        prefsFile = File(base, "feed-preferences.md")
        reload()
        refreshSandbox()
    }

    fun reload() {
        val all = root.listFiles()?.filter(FeedPost::isDayDir)
            ?.sortedByDescending { it.name }
            ?.flatMap { day -> day.listFiles()?.mapNotNull(FeedPost::parse).orEmpty().sortedWith(DAY_ORDER) }
            .orEmpty()
            .filter(FeedFlow::isCoachPost) // Mosaic
        _posts.value = all
        _preferences.value = runCatching { prefsFile.takeIf { it.exists() }?.readText() }.getOrNull()
            ?.trim().orEmpty().ifEmpty { defaultPreferences() }
    }

    // Mosaic: the page coaches now; the default sentence steers the training, not a news feed.
    fun defaultPreferences(): String = appContext.getString(R.string.nm_growth_default_steer)

    fun savePreferences(text: String) {
        runCatching {
            prefsFile.parentFile?.mkdirs()
            prefsFile.writeText(text.trim() + "\n")
        }.onFailure { AppLogger.warning(TAG, "preferences not saved: ${it.message}") }
        _preferences.value = text.trim().ifEmpty { defaultPreferences() }
    }

    fun delete(post: FeedPost) {
        runCatching { post.file.delete() }
            .onSuccess { refreshSandbox() }
        _posts.value = _posts.value.filterNot { it.file == post.file }
    }

    /**
     * Writes a batch of posts for today, continuing today's numbering. Returns what was written.
     * Mosaic: a post's number is its id, and answers are kept by id, so a number used by a deleted
     * card (still named in the growth record) is not handed out again; the day's limit counts the
     * cards that are there, not the numbers used.
     */
    fun append(drafts: List<Draft>, now: Long = System.currentTimeMillis()): List<FeedPost> {
        if (drafts.isEmpty()) return emptyList()
        val day = DAY.format(Date(now))
        val dir = File(root, day).apply { mkdirs() }
        val present = dir.listFiles()?.mapNotNull { FeedPost.parse(it)?.index }.orEmpty()
        val answered = io.github.nanomuse.growth.GrowthStore.responses.value.keys
            .mapNotNull { id -> id.takeIf { it.startsWith("$day/") }?.substringAfter('/')?.toIntOrNull() }
        var next = ((present + answered).maxOrNull() ?: 0) + 1
        var room = MAX_POSTS_PER_DAY - present.size
        val written = mutableListOf<FeedPost>()
        for (d in drafts) {
            if (room <= 0 || next > MAX_INDEX) break
            val file = File(dir, "%02d.md".format(Locale.ROOT, next))
            val post = FeedPost(
                day = day, index = next, title = d.title.trim().take(80), type = d.type, emoji = d.emoji,
                body = d.body.trim(), source = d.source, createdAt = now, liked = false, file = file,
                track = d.track, level = d.level, prompt = d.prompt.trim(), unit = d.unit.trim(),
            )
            runCatching { file.writeText(post.serialize()) }
                .onSuccess { written += post; next++; room-- }
                .onFailure { AppLogger.warning(TAG, "post not written: ${it.message}") }
        }
        prune()
        reload()
        refreshSandbox()
        AppLogger.info(TAG, "wrote ${written.size} post(s) for $day")
        return written
    }

    private fun refreshSandbox() {
        runCatching { FeedSandboxScope.refresh(appContext) }
            .onFailure { AppLogger.warning(TAG, "sandbox feed not refreshed: ${it.message}") }
    }

    private fun prune() {
        val days = root.listFiles()?.filter(FeedPost::isDayDir)?.sortedByDescending { it.name }.orEmpty()
        days.drop(KEEP_DAYS).forEach { it.deleteRecursively() }
    }

    fun hasAnyPost(): Boolean = _posts.value.isNotEmpty()

    fun latestDay(): String? = _posts.value.firstOrNull()?.day

    data class Draft(
        val title: String,
        val type: String,
        val emoji: String,
        val body: String,
        val source: List<String>,
        val track: String? = null, // Mosaic: the ability a practice card trains
        val level: Int = 0,
        val prompt: String = "",
        val unit: String = "", // Mosaic: the course unit, "1.2 …"
    )

    private val DAY = SimpleDateFormat("yyyy-MM-dd", Locale.US)

    /**
     * The order of one day's posts on the page. A batch is written in one go, so its posts share
     * a `created` time: the newest batch (the evening's) comes first, and inside a batch the posts
     * keep their numbering, which is the model's order, most important first. Sorting the whole
     * day by index put the morning's batch on top and the newest one at the bottom (#555).
     */
    val DAY_ORDER: Comparator<FeedPost> = compareByDescending<FeedPost> { it.createdAt }.thenBy { it.index }
}
