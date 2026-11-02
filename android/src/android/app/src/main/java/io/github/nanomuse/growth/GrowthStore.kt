package io.github.nanomuse.growth

import android.content.Context
import com.openminis.app.R
import com.openminis.app.logging.AppLogger
import io.github.nanomuse.feed.FeedPost
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/** One ability being trained, from Beginner (1) to Expert (5). */
data class GrowthTrack(
    val id: String,
    /** Null for a built-in ability, whose title comes from the resources. */
    val title: String?,
    /** What a user-added ability is for, in their words. */
    val about: String?,
    /** The skill that holds the method, the card kinds and the rubric. */
    val skill: String,
    val status: String,
    val level: Int,
    /** Graded answers to practice cards of the current level, oldest first, and the day of each. */
    val scores: List<Int>,
    val scoreDays: List<String>,
    val lastCardAt: Long?,
    val reachedAt: Long?,
    /** The practice record qualifies: a level check decides the next level. */
    val challenge: Boolean = false,
) {
    fun title(context: Context): String = title ?: BUILT_IN[id]?.let(context::getString) ?: id

    companion object {
        val BUILT_IN = linkedMapOf(
            "principles" to R.string.nm_growth_track_principles,
            "lenses" to R.string.nm_growth_track_lenses,
            "english" to R.string.nm_growth_track_english,
            "expression" to R.string.nm_growth_track_expression,
            "leadership" to R.string.nm_growth_track_leadership,
            "habits" to R.string.nm_growth_track_habits,
        )
    }
}

/** An answer to a practice card and, once reviewed, its score (0 to 4) and feedback. */
data class GrowthResponse(
    val post: String,
    val track: String,
    val level: Int,
    val prompt: String,
    val answer: String,
    val answeredAt: Long,
    val score: Int? = null,
    val feedback: String? = null,
    val gradedAt: Long? = null,
    /** The card's type: theory, practice, challenge, review or action. */
    val kind: String = "practice",
    /** How the card felt to the person: too_easy, ok or too_hard. */
    val difficulty: String? = null,
    /** The course unit of the card, as the skill numbers it. */
    val unit: String = "",
)

/** A point worth remembering from a review, brought back at growing intervals. */
data class RecallItem(
    val id: String,
    val track: String,
    val question: String,
    val answer: String,
    val due: Long,
    val intervalDays: Int,
    val reps: Int,
    val lapses: Int,
)

data class GrowthState(val target: Int, val tracks: List<GrowthTrack>, val offered: Set<String>) {
    val focus: GrowthTrack? get() = tracks.firstOrNull { it.status == GrowthStore.FOCUS }

    /** The ability in training reached the goal and the person has not been asked at this level yet. */
    val promotion: GrowthTrack? get() = focus?.takeIf { it.level >= target && "${it.id}:${it.level}" !in offered }

    fun next(): GrowthTrack? = tracks.firstOrNull { it.status == GrowthStore.QUEUED }
}

/**
 * The growth record behind the feed: which abilities are trained in what order, how far each
 * has come, every answer with its review, the points to recall, and two files the agent keeps
 * about the person (`MEMORY.md`, how they learn; `PRINCIPLES.md`, the principles they adopted).
 * Plain files under `minis-global/nanomuse/growth/`, like the feed itself.
 *
 * Levels follow mastery learning: six answers at the current level to scenario and real-life cards
 * (theory cards are reviewed and recalled but do not count) averaging 3 of 4 or better over at
 * least four days unlock a level check, a harder card; scoring 3 or more on it
 * raises the level, less sends the ability back for a few more practice answers. An ability kept
 * up after reaching its goal drops one level when its last three reviews average under 1.5. One
 * ability is trained at a time; once it reaches the goal, the next one in the queue is offered.
 */
object GrowthStore {
    const val FOCUS = "focus"
    const val QUEUED = "queued"
    const val MAINTAIN = "maintain"
    const val PAUSED = "paused"
    const val MAX_LEVEL = 5
    const val WINDOW = 6
    const val RECALL_PER_DAY = 5
    private const val PASS_MEAN = 3.0
    private const val MIN_DAYS = 4
    private const val DROP_WINDOW = 3
    private const val DROP_MEAN = 1.5
    private const val KEEP_RESPONSES = 500
    private const val KEEP_OBSERVATIONS = 40
    private const val KEEP_RECALL = 300
    private const val MAX_FRAMEWORK = 6000
    private const val TAG = "Growth"

    private lateinit var dir: File
    private lateinit var skillsRoot: File
    private lateinit var appContext: Context

    private val _state = MutableStateFlow(GrowthState(3, emptyList(), emptySet()))
    val state: StateFlow<GrowthState> = _state

    private val _responses = MutableStateFlow<Map<String, GrowthResponse>>(emptyMap())
    /** Latest record per feed post id. */
    val responses: StateFlow<Map<String, GrowthResponse>> = _responses

    private val _recall = MutableStateFlow<List<RecallItem>>(emptyList())
    val recall: StateFlow<List<RecallItem>> = _recall

    fun init(context: Context) {
        appContext = context.applicationContext
        dir = File(context.filesDir, "minis-global/nanomuse/growth").apply { mkdirs() }
        skillsRoot = File(context.filesDir, "minis-global/skills")
        reload()
    }

    @Synchronized
    fun reload() {
        if (!::dir.isInitialized) return
        _state.value = runCatching { File(dir, "state.json").takeIf { it.exists() }?.readText()?.let(::parseState) }
            .getOrNull() ?: defaults().also(::writeState)
        _responses.value = readResponses()
        _recall.value = readRecall()
    }

    fun memoryFile(): File = File(dir, "MEMORY.md")
    private fun observationsFile(): File = File(dir, "observations.md")
    fun principlesFile(): File = File(dir, "PRINCIPLES.md")
    fun read(file: File): String = runCatching { file.takeIf { it.exists() }?.readText()?.trim() }.getOrNull().orEmpty()

    // ── answers and reviews ────────────────────────────────────────────────

    @Synchronized
    fun recordAnswer(post: FeedPost, answer: String) {
        val track = post.track ?: return
        save(GrowthResponse(post.id, track, post.level, post.prompt, answer, System.currentTimeMillis(), kind = post.type, unit = post.unit))
    }

    /** Applies a review; returns false when there is no answer to the post. */
    @Synchronized
    fun recordGrade(postId: String, score: Int, feedback: String): Boolean {
        val response = _responses.value[postId] ?: return false
        val now = System.currentTimeMillis()
        val value = score.coerceIn(0, 4)
        save(response.copy(score = value, feedback = feedback, gradedAt = now))
        if (response.score != null) return true // a second review replaces the text, not the count
        val track = _state.value.tracks.firstOrNull { it.id == response.track } ?: return true
        if (response.level != track.level) return true // a card from another level does not move this one
        if (response.kind == "theory") return true // understanding is reviewed and recalled; the level moves on what the person can do
        updateTrack(track.id) { if (response.kind == "challenge") checkLevel(it, value, now) else applyScore(it, value, now) }
        return true
    }

    private fun applyScore(t: GrowthTrack, score: Int, now: Long): GrowthTrack {
        val scores = (t.scores + score).takeLast(WINDOW * 2)
        val days = (t.scoreDays + DAY.format(Date(now))).takeLast(WINDOW * 2)
        val window = scores.takeLast(WINDOW)
        return when {
            t.level < MAX_LEVEL && window.size >= WINDOW && window.average() >= PASS_MEAN && days.takeLast(WINDOW).distinct().size >= MIN_DAYS ->
                t.copy(scores = scores, scoreDays = days, challenge = true)
            t.status == MAINTAIN && t.level > 1 && scores.size >= DROP_WINDOW && scores.takeLast(DROP_WINDOW).average() < DROP_MEAN ->
                t.copy(level = t.level - 1, scores = emptyList(), scoreDays = emptyList(), reachedAt = now, challenge = false)
            else -> t.copy(scores = scores, scoreDays = days)
        }
    }

    /** The level check: 3 or more raises the level; less keeps three practice answers, so three more good ones reopen it. */
    private fun checkLevel(t: GrowthTrack, score: Int, now: Long): GrowthTrack =
        if (score >= 3 && t.level < MAX_LEVEL) t.copy(level = t.level + 1, scores = emptyList(), scoreDays = emptyList(), reachedAt = now, challenge = false)
        else t.copy(scores = t.scores.takeLast(DROP_WINDOW), scoreDays = t.scoreDays.takeLast(DROP_WINDOW), challenge = false)

    @Synchronized
    fun setDifficulty(postId: String, difficulty: String) {
        val response = _responses.value[postId] ?: return
        if (response.difficulty != difficulty) save(response.copy(difficulty = difficulty))
    }

    /** Cards were written for these abilities: their review clock starts again. */
    @Synchronized
    fun cardsWritten(posts: List<FeedPost>) {
        val now = System.currentTimeMillis()
        posts.mapNotNull { it.track }.distinct().forEach { id -> updateTrack(id) { it.copy(lastCardAt = now) } }
    }

    fun ungraded(): List<GrowthResponse> = _responses.value.values.filter { it.score == null }.sortedBy { it.answeredAt }

    fun recentGraded(limit: Int): List<GrowthResponse> =
        _responses.value.values.filter { it.score != null }.sortedByDescending { it.gradedAt ?: 0 }.take(limit)

    /** Cards of this ability from the last [days] days still waiting for an answer: the real-life tasks when [action], the rest otherwise. */
    fun unanswered(trackId: String, posts: List<FeedPost>, days: Int, action: Boolean): List<FeedPost> {
        val since = System.currentTimeMillis() - days * DAY_MS
        return posts.filter {
            it.track == trackId && it.prompt.isNotBlank() && it.createdAt >= since && it.id !in _responses.value && (it.type == "action") == action
        }
    }

    /** Days in a row, up to today or yesterday, with at least one answer. */
    @Synchronized
    fun streak(now: Long = System.currentTimeMillis()): Int {
        val days = _responses.value.values.map { DAY.format(Date(it.answeredAt)) }.toSet()
        var day = now
        if (DAY.format(Date(day)) !in days) day -= DAY_MS
        var count = 0
        while (DAY.format(Date(day)) in days) { count++; day -= DAY_MS }
        return count
    }

    // ── recall ─────────────────────────────────────────────────────────────

    @Synchronized
    fun addRecall(track: String, question: String, answer: String) {
        val q = question.trim().take(200).ifEmpty { return }
        val a = answer.trim().take(400).ifEmpty { return }
        if (_recall.value.any { it.question == q }) return
        val item = RecallItem(System.currentTimeMillis().toString(36), track, q, a, startOfDay(System.currentTimeMillis()) + DAY_MS, 1, 0, 0)
        writeRecall((_recall.value + item).takeLast(KEEP_RECALL))
    }

    /** Items due today, oldest due first, at most [RECALL_PER_DAY]. */
    fun dueRecall(now: Long = System.currentTimeMillis()): List<RecallItem> =
        _recall.value.filter { it.due <= now }.sortedBy { it.due }.take(RECALL_PER_DAY)

    /**
     * A self-rating, the way flashcards work: remembered stretches the interval about 2.5 times,
     * vague about 1.3 times, forgot brings it back tomorrow.
     */
    @Synchronized
    fun rateRecall(id: String, rating: String) {
        val now = System.currentTimeMillis()
        writeRecall(_recall.value.map { item ->
            if (item.id != id) item else {
                val days = when (rating) {
                    "good" -> (item.intervalDays * 2.5).toInt().coerceAtLeast(item.intervalDays + 1)
                    "hard" -> (item.intervalDays * 1.3).toInt().coerceAtLeast(1)
                    else -> 1
                }.coerceAtMost(180)
                item.copy(due = startOfDay(now) + days * DAY_MS, intervalDays = days, reps = item.reps + 1,
                    lapses = item.lapses + if (rating == "again") 1 else 0)
            }
        })
    }

    /** Points forgotten more than once, for the feed to work back in. */
    fun weakRecall(limit: Int): List<RecallItem> = _recall.value.filter { it.lapses >= 2 }.sortedByDescending { it.lapses }.take(limit)

    // ── the person's choices ───────────────────────────────────────────────

    @Synchronized
    fun setFocus(id: String) = mutate { s ->
        s.copy(tracks = s.tracks.map { t ->
            when {
                t.id == id -> t.copy(status = FOCUS, level = t.level.coerceAtLeast(1))
                t.status == FOCUS -> t.copy(status = if (t.level >= s.target) MAINTAIN else QUEUED)
                else -> t
            }
        })
    }

    /** "Move on": the ability in training is kept up from now on, the next in the queue starts. */
    @Synchronized
    fun advance() = mutate { s ->
        val focus = s.focus ?: return@mutate s
        val next = s.next()
        s.copy(
            tracks = s.tracks.map { t ->
                when (t.id) {
                    focus.id -> t.copy(status = MAINTAIN)
                    next?.id -> t.copy(status = FOCUS)
                    else -> t
                }
            },
            offered = s.offered + "${focus.id}:${focus.level}",
        )
    }

    /** "Keep going": no more asking until this ability reaches the next level. */
    @Synchronized
    fun keepGoing() = mutate { s -> s.focus?.let { s.copy(offered = s.offered + "${it.id}:${it.level}") } ?: s }

    @Synchronized
    fun setTarget(level: Int) = mutate { it.copy(target = level.coerceIn(2, MAX_LEVEL)) }

    @Synchronized
    fun setPaused(id: String, paused: Boolean) = mutate { s ->
        s.copy(tracks = s.tracks.map { t ->
            if (t.id != id) t else t.copy(status = if (paused) PAUSED else if (t.level >= s.target) MAINTAIN else QUEUED)
        })
    }

    /** Moves an ability one place up; the queue order is the training order. */
    @Synchronized
    fun moveUp(id: String) = mutate { s ->
        val i = s.tracks.indexOfFirst { it.id == id }
        if (i <= 0) s else s.copy(tracks = s.tracks.toMutableList().apply { add(i - 1, removeAt(i)) })
    }

    /** Adds an ability the person named and returns its id; [skill] is its own course when one is being written for it. */
    @Synchronized
    fun add(title: String, about: String, skill: String? = null): String {
        val id = "custom-" + System.currentTimeMillis().toString(36)
        mutate { s ->
            s.copy(tracks = s.tracks + GrowthTrack(id, title.trim().take(30), about.trim().take(200), skill ?: GENERAL_SKILL,
                if (s.focus == null) FOCUS else QUEUED, 1, emptyList(), emptyList(), null, null))
        }
        return id
    }

    /** The ability is trained by [skill] from the next card on (its own course, written in a chat). */
    @Synchronized
    fun setSkill(id: String, skill: String) = updateTrack(id) { it.copy(skill = skill) }

    /** Only abilities the person added can be removed; the built-in ones can be paused. */
    @Synchronized
    fun remove(id: String) = mutate { s -> s.copy(tracks = s.tracks.filterNot { it.id == id && it.title != null }) }

    // ── the agent's files ──────────────────────────────────────────────────

    /** The reviewer's notes since the last summary, one line each, in `observations.md`. */
    fun observations(): List<String> = read(observationsFile()).lines().map { it.trim() }.filter { it.startsWith("- ") }

    /** One line the reviewer noticed about how the person learns. */
    @Synchronized
    fun observe(trackId: String, line: String) {
        val text = line.replace("\n", " ").trim().take(200).ifEmpty { return }
        val all = (observations() + "- ${DAY.format(Date())} $trackId: $text").takeLast(KEEP_OBSERVATIONS)
        writeAtomically(observationsFile(), all.joinToString("\n") + "\n")
    }

    /** The weekly rewrite: `MEMORY.md` becomes the new summary, which already folds the observations in. */
    @Synchronized
    fun replaceMemory(summary: String) {
        writeAtomically(memoryFile(), summary.trim().take(2000) + "\n")
        writeAtomically(observationsFile(), "")
    }

    fun observationCount(): Int = observations().size

    @Synchronized
    fun addPrinciple(text: String, category: String?, from: String?) {
        val line = text.replace("\n", " ").trim().take(200).ifEmpty { return }
        val existing = read(principlesFile())
        if (existing.lineSequence().any { it.contains(line) }) return
        val tag = category?.trim()?.takeIf { it.isNotEmpty() }?.let { "[$it] " }.orEmpty()
        val origin = listOfNotNull(from?.trim()?.takeIf { it.isNotEmpty() }, DAY.format(Date())).joinToString(", ")
        val entry = "- $tag$line ($origin)\n"
        writeAtomically(principlesFile(),
            if (existing.isEmpty()) "# ${appContext.getString(R.string.nm_growth_principles)}\n\n$entry" else "$existing\n$entry")
    }

    // ── the courses ────────────────────────────────────────────────────────

    /**
     * An ability's course is its skill's folder (`/var/minis/skills/<skill>/` in the sandbox): `SKILL.md`
     * (the course), `books/` (one card per book), `FRAMEWORK.md` (the person's framework, grown by the
     * coach) and `ADJUSTMENTS.md` (changes the coach made from the person's real-world reports).
     */
    fun courseDir(skill: String): File? =
        skill.takeIf { ::skillsRoot.isInitialized && it.isNotBlank() && '/' !in it && '\\' !in it && ".." !in it }?.let { File(skillsRoot, it) }

    /** The course's book cards, B01 first: file name and text. */
    fun bookCards(skill: String): List<Pair<String, String>> =
        courseDir(skill)?.let { File(it, "books") }?.listFiles { f -> f.isFile && f.name.endsWith(".md") }
            ?.sortedBy { it.name }?.map { it.name to read(it) }?.filter { it.second.isNotEmpty() }.orEmpty()

    fun framework(skill: String): String = courseDir(skill)?.let { read(File(it, "FRAMEWORK.md")) }.orEmpty()

    /** The coach's rewrite of the person's framework replaces the file. */
    @Synchronized
    fun writeFramework(skill: String, text: String) {
        val folder = courseDir(skill) ?: return
        val body = text.trim().take(MAX_FRAMEWORK).ifEmpty { return }
        folder.mkdirs()
        runCatching { writeAtomically(File(folder, "FRAMEWORK.md"), body + "\n") }
            .onFailure { AppLogger.warning(TAG, "framework not saved: ${it.message}") }
    }

    /** The course changes in force, one line each, oldest first. */
    fun adjustments(skill: String): List<String> =
        courseDir(skill)?.let { read(File(it, "ADJUSTMENTS.md")) }.orEmpty().lines().map { it.trim() }.filter { it.startsWith("- ") }

    @Synchronized
    fun addAdjustment(skill: String, change: String) {
        val folder = courseDir(skill) ?: return
        val line = change.replace("\n", " ").trim().take(300).ifEmpty { return }
        val file = File(folder, "ADJUSTMENTS.md")
        val existing = read(file)
        if (existing.lineSequence().any { it.contains(line) }) return
        folder.mkdirs()
        runCatching {
            writeAtomically(file, (if (existing.isEmpty()) "# ${appContext.getString(R.string.nm_growth_adjustments)}\n\n" else "$existing\n") +
                "- ${DAY.format(Date())} $line\n")
        }.onFailure { AppLogger.warning(TAG, "adjustment not saved: ${it.message}") }
    }

    // ── storage ────────────────────────────────────────────────────────────

    private fun defaults(): GrowthState = GrowthState(
        target = 3,
        tracks = GrowthTrack.BUILT_IN.keys.mapIndexed { i, id ->
            GrowthTrack(id, null, null, "growth-$id", if (i == 0) FOCUS else QUEUED, 1, emptyList(), emptyList(), null, null)
        },
        offered = emptySet(),
    )

    private fun mutate(change: (GrowthState) -> GrowthState) {
        val next = change(_state.value)
        if (next == _state.value) return
        _state.value = next
        writeState(next)
    }

    private fun updateTrack(id: String, change: (GrowthTrack) -> GrowthTrack) =
        mutate { s -> s.copy(tracks = s.tracks.map { if (it.id == id) change(it) else it }) }

    private fun save(response: GrowthResponse) {
        _responses.value = _responses.value + (response.post to response)
        val file = File(dir, "responses.jsonl")
        runCatching {
            file.appendText(toJson(response).toString() + "\n")
            if (file.readLines().size > KEEP_RESPONSES * 2) {
                val keep = _responses.value.values.sortedBy { it.answeredAt }.takeLast(KEEP_RESPONSES)
                writeAtomically(file, keep.joinToString("") { toJson(it).toString() + "\n" })
            }
        }.onFailure { AppLogger.warning(TAG, "answer not saved: ${it.message}") }
    }

    private fun readResponses(): Map<String, GrowthResponse> {
        val file = File(dir, "responses.jsonl")
        if (!file.exists()) return emptyMap()
        val out = LinkedHashMap<String, GrowthResponse>()
        runCatching { file.readLines() }.getOrDefault(emptyList()).forEach { line ->
            val o = runCatching { JSONObject(line) }.getOrNull() ?: return@forEach
            val post = o.optString("post").ifEmpty { return@forEach }
            out[post] = GrowthResponse(
                post = post,
                track = o.optString("track"),
                level = o.optInt("level"),
                prompt = o.optString("prompt"),
                answer = o.optString("answer"),
                answeredAt = o.optLong("answered_at"),
                score = o.optIntOrNull("score"),
                feedback = o.optStringOrNull("feedback"),
                gradedAt = o.optLongOrNull("graded_at"),
                kind = o.optStringOrNull("kind") ?: "practice",
                difficulty = o.optStringOrNull("difficulty"),
                unit = o.optStringOrNull("unit").orEmpty(),
            )
        }
        return out
    }

    private fun toJson(r: GrowthResponse) = JSONObject().put("post", r.post).put("track", r.track).put("level", r.level)
        .put("prompt", r.prompt).put("answer", r.answer).put("answered_at", r.answeredAt)
        .put("score", r.score ?: JSONObject.NULL).put("feedback", r.feedback ?: JSONObject.NULL)
        .put("graded_at", r.gradedAt ?: JSONObject.NULL).put("kind", r.kind).put("difficulty", r.difficulty ?: JSONObject.NULL).put("unit", r.unit)

    private fun readRecall(): List<RecallItem> = runCatching {
        val a = JSONArray(File(dir, "recall.json").readText())
        (0 until a.length()).map { i ->
            val o = a.getJSONObject(i)
            RecallItem(o.getString("id"), o.optString("track"), o.getString("q"), o.getString("a"),
                o.optLong("due"), o.optInt("interval", 1), o.optInt("reps"), o.optInt("lapses"))
        }
    }.getOrDefault(emptyList())

    private fun writeRecall(items: List<RecallItem>) {
        _recall.value = items
        runCatching {
            writeAtomically(File(dir, "recall.json"), JSONArray(items.map {
                JSONObject().put("id", it.id).put("track", it.track).put("q", it.question).put("a", it.answer)
                    .put("due", it.due).put("interval", it.intervalDays).put("reps", it.reps).put("lapses", it.lapses)
            }).toString(2))
        }.onFailure { AppLogger.warning(TAG, "recall not saved: ${it.message}") }
    }

    private fun writeState(s: GrowthState) {
        val json = JSONObject().put("version", 1).put("target", s.target).put("offered", JSONArray(s.offered.toList()))
            .put("tracks", JSONArray(s.tracks.map { t ->
                JSONObject().put("id", t.id).put("title", t.title ?: JSONObject.NULL).put("about", t.about ?: JSONObject.NULL)
                    .put("skill", t.skill).put("status", t.status).put("level", t.level)
                    .put("scores", JSONArray(t.scores)).put("score_days", JSONArray(t.scoreDays))
                    .put("last_card_at", t.lastCardAt ?: JSONObject.NULL).put("reached_at", t.reachedAt ?: JSONObject.NULL)
                    .put("challenge", t.challenge)
            }))
        runCatching { writeAtomically(File(dir, "state.json"), json.toString(2)) }
            .onFailure { AppLogger.warning(TAG, "state not saved: ${it.message}") }
    }

    private fun parseState(text: String): GrowthState {
        val o = JSONObject(text)
        val tracks = o.getJSONArray("tracks").let { a ->
            (0 until a.length()).map { i ->
                val t = a.getJSONObject(i)
                val scores = t.optJSONArray("scores")
                val days = t.optJSONArray("score_days")
                GrowthTrack(
                    id = t.getString("id"),
                    title = t.optStringOrNull("title")?.takeIf { it.isNotBlank() },
                    about = t.optStringOrNull("about")?.takeIf { it.isNotBlank() },
                    skill = t.optString("skill").ifEmpty { GENERAL_SKILL },
                    status = t.optString("status").takeIf { it in setOf(FOCUS, QUEUED, MAINTAIN, PAUSED) } ?: QUEUED,
                    level = t.optInt("level", 1).coerceIn(1, MAX_LEVEL),
                    scores = scores?.let { s -> (0 until s.length()).map { s.optInt(it) } }.orEmpty(),
                    scoreDays = days?.let { d -> (0 until d.length()).map { d.optString(it) } }.orEmpty(),
                    lastCardAt = t.optLongOrNull("last_card_at"),
                    reachedAt = t.optLongOrNull("reached_at"),
                    challenge = t.optBoolean("challenge", false),
                )
            }
        }
        val offered = o.optJSONArray("offered")?.let { a -> (0 until a.length()).map { a.optString(it) }.toSet() }.orEmpty()
        return GrowthState(o.optInt("target", 3).coerceIn(2, MAX_LEVEL), tracks, offered)
    }

    private fun JSONObject.optStringOrNull(key: String): String? = if (has(key) && !isNull(key)) optString(key) else null
    private fun JSONObject.optLongOrNull(key: String): Long? = if (has(key) && !isNull(key)) optLong(key) else null
    private fun JSONObject.optIntOrNull(key: String): Int? = if (has(key) && !isNull(key)) optInt(key) else null

    private fun writeAtomically(file: File, text: String) {
        val tmp = File(file.parentFile, file.name + ".tmp")
        tmp.writeText(text)
        if (!tmp.renameTo(file)) { file.writeText(text); tmp.delete() }
    }

    private fun startOfDay(now: Long): Long = java.util.Calendar.getInstance().apply {
        timeInMillis = now
        set(java.util.Calendar.HOUR_OF_DAY, 0); set(java.util.Calendar.MINUTE, 0)
        set(java.util.Calendar.SECOND, 0); set(java.util.Calendar.MILLISECOND, 0)
    }.timeInMillis

    const val GENERAL_SKILL = "growth-general"
    private const val DAY_MS = 24 * 60 * 60 * 1000L
    private val DAY = SimpleDateFormat("yyyy-MM-dd", Locale.US)
}
