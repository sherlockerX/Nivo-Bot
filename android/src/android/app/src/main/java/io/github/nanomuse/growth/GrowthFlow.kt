package io.github.nanomuse.growth

import android.content.Context
import com.openminis.app.MinisApp
import com.openminis.app.R
import com.openminis.app.debug.HeadlessChatRunner
import com.openminis.app.logging.AppLogger
import com.openminis.app.ui.chat.ChatViewModelStore
import io.github.nanomuse.feed.FeedFlow
import io.github.nanomuse.feed.FeedPost
import io.github.nanomuse.feed.FeedStore
import io.github.nanomuse.routines.ScheduledRunScopes
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import org.json.JSONObject
import java.util.Calendar

/**
 * How the coach trains: which cards today brings (the plan), what the coach's conversation is told
 * (the ability list, the course units so far, the skills of today's abilities, the answers waiting
 * for review, the growth memory and the principles), and the review of an answer, which runs as one
 * turn in that conversation as soon as the answer is submitted. The model only scores; the levels
 * move in [GrowthStore] by fixed rules.
 *
 * Each ability is a course in its skill: books, then units by level, each unit split into theory
 * (what to understand), practice (a scenario drill) and action (something done in real life and
 * reported back). The page carries training cards only; information the person wants delivered
 * belongs in a scheduled task.
 */
object GrowthFlow {
    const val GRADE_BLOCK = "nanomuse-grade"
    const val MEMORY_BLOCK = "nanomuse-memory"
    /** A change to an ability's course, from the person's real-world reports: {"track", "change"}. */
    const val COURSE_BLOCK = "nanomuse-course"
    /** The whole new FRAMEWORK.md of an ability; the fence line names it: ```nanomuse-framework track=<id>. */
    const val FRAMEWORK_BLOCK = "nanomuse-framework"
    private const val TAG = "Growth"
    private const val DAY_MS = 24 * 60 * 60 * 1000L
    private const val SKILL_CHARS = 6000
    private const val BOOK_CHARS = 12000
    private val gradeBlock = Regex("```$GRADE_BLOCK[ \\t]*\\r?\\n([\\s\\S]*?)```")
    private val memoryBlock = Regex("```$MEMORY_BLOCK[ \\t]*\\r?\\n([\\s\\S]*?)```")
    private val courseBlock = Regex("```$COURSE_BLOCK[ \\t]*\\r?\\n([\\s\\S]*?)```")
    private val frameworkBlock = Regex("```$FRAMEWORK_BLOCK[ \\t]+track=([A-Za-z0-9_-]+)[ \\t]*\\r?\\n([\\s\\S]*?)```")
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    private val _grading = MutableStateFlow<Set<String>>(emptySet())
    /** Posts whose answer is being reviewed right now. */
    val grading: StateFlow<Set<String>> = _grading

    data class Slot(val track: GrowthTrack, val kind: String, val count: Int)

    /**
     * Today's cards for the ability in training: a theory card, a scenario drill (the level check
     * instead once it is unlocked; none while three recent cards wait for an answer), and a task
     * for real life while none from the last week waits for its report. Then a review for the
     * kept-up ability that is most overdue; with nothing in training, reviews for the two most
     * overdue. Higher levels are reviewed less often.
     */
    fun plan(posts: List<FeedPost>, now: Long = System.currentTimeMillis()): List<Slot> {
        val s = GrowthStore.state.value
        val slots = mutableListOf<Slot>()
        s.focus?.let { f ->
            val backlog = GrowthStore.unanswered(f.id, posts, 3, action = false).size >= 3
            slots += Slot(f, "theory", 1)
            if (f.challenge) slots += Slot(f, "challenge", 1) else if (!backlog) slots += Slot(f, "practice", 1)
            if (GrowthStore.unanswered(f.id, posts, 7, action = true).isEmpty()) slots += Slot(f, "action", 1)
        }
        s.tracks.filter { it.status == GrowthStore.MAINTAIN && now - (it.lastCardAt ?: 0L) >= reviewEvery(it.level) }
            .sortedBy { it.lastCardAt ?: 0L }
            .take(if (s.focus == null) 2 else 1)
            .forEach { slots += Slot(it, if (it.challenge) "challenge" else "review", 1) }
        return slots
    }

    /** Sunday's report is written once a week. */
    private fun weeklyDue(posts: List<FeedPost>, now: Long): Boolean =
        Calendar.getInstance().apply { timeInMillis = now }.get(Calendar.DAY_OF_WEEK) == Calendar.SUNDAY &&
            posts.none { it.type == "weekly" && now - it.createdAt < 6 * DAY_MS }

    private fun reviewEvery(level: Int): Long = DAY_MS * when {
        level <= 2 -> 2
        level == 3 -> 3
        level == 4 -> 7
        else -> 14
    }

    /**
     * The course units an ability went through at its current level, in the order they came up,
     * with the scores per card kind ("?" answered and not reviewed yet, "open" not answered).
     */
    private fun unitLines(t: GrowthTrack, posts: List<FeedPost>): List<String> {
        val answered = GrowthStore.responses.value
        val done = answered.values.filter { it.track == t.id && it.level == t.level && it.unit.isNotBlank() }.sortedBy { it.answeredAt }
        val open = posts.filter { it.track == t.id && it.level == t.level && it.unit.isNotBlank() && it.id !in answered }.sortedBy { it.createdAt }
        return (done.map { it.unit } + open.map { it.unit }).distinct().map { unit ->
            val kinds = listOf("theory", "practice", "action", "challenge").mapNotNull { kind ->
                val marks = done.filter { it.unit == unit && it.kind == kind }.map { it.score?.toString() ?: "?" } +
                    open.filter { it.unit == unit && it.type == kind }.map { "open" }
                if (marks.isEmpty()) null else "$kind ${marks.joinToString(",")}"
            }
            "- $unit: ${kinds.joinToString("; ")}"
        }
    }

    /** The growth part of the coach conversation's system prompt. */
    fun section(context: Context, posts: List<FeedPost>): String {
        val s = GrowthStore.state.value
        val slots = plan(posts)
        val pending = GrowthStore.ungraded().take(6)
        val levels = context.resources.getStringArray(R.array.nm_growth_levels)
        val needed = (slots.map { it.track } + pending.mapNotNull { r -> s.tracks.firstOrNull { it.id == r.track } }).distinctBy { it.id }
        val now = System.currentTimeMillis()
        return buildString {
            appendLine("## Coaching: the only job of this conversation")
            appendLine(
                "This conversation coaches the user on the Coach tab. Its cards train the user's abilities one at a time, and you review every answer. " +
                    "Write training cards and nothing else: no news, no paper or article summaries, no information digests, no general posts, whatever the standing instruction says. " +
                    "Information the user wants delivered belongs in their scheduled tasks; the standing instruction only steers the material and the emphasis of the cards.",
            )
            appendLine()
            appendLine(
                "Who you are training: a capable young adult who understands fast, follows through and can change a great deal, but who starts from zero in these abilities. " +
                    "Their upbringing taught them little about social and practical life, so assume no prior knowledge: one idea at a time, plain words, examples from ordinary life, " +
                    "and concrete steps and words to say. Be direct; no flattery, no lectures. Their own profile is USER.md above, once they have written it. " +
                    "Never hand out conclusions as truths about them: they answer first, your view comes after theirs with the strongest counter-view, and you say what is evidence and what is your guess.",
            )
            appendLine()
            appendLine("How each ability is trained (its skill below holds the books and the course, unit by unit and level by level):")
            appendLine(
                "- theory card, the knowledge to build: one idea from the current unit, in your own words (never quote the book at length): what it says, why it holds, " +
                    "where it stops holding, one everyday example, and the book and part it comes from. Its prompt asks the user to restate it in their own words and give an example from their own life.",
            )
            appendLine(
                "- practice card, a scenario drill: a concrete situation the user is likely to meet; the prompt asks what they would do or say. " +
                    "At level 1 the body may name what to watch for, never the plan itself. Your review then gives a response plan they can follow: steps and sentences.",
            )
            appendLine(
                "- action card, what must be done in real life: give it directly, no warm-up: what to do, when, how (the steps, the exact words), and what to watch for. " +
                    "Its prompt asks them to come back after doing it: what they did, how the other side reacted, what came of it, what they would change. " +
                    "The user makes the chance to do it; the real result is the feedback they correct themselves by.",
            )
            appendLine(
                "- Within the current level, units go in the order the skill lists them: theory first, then practice, then action. " +
                    "Move to the next unit once its theory and one practice or action have scored 3 or more; stay longer on a unit whose scores are low.",
            )
            appendLine()
            appendLine("Abilities (id · name · status · level of 5 · recent scores at this level, 0 to 4):")
            s.tracks.forEach { t ->
                appendLine(
                    "- ${t.id} · ${t.title(context)} · ${t.status} · L${t.level} ${levels.getOrElse(t.level - 1) { "" }} · " +
                        t.scores.takeLast(GrowthStore.WINDOW).joinToString(",").ifEmpty { "no scores yet" } +
                        (if (t.challenge) " · level check unlocked" else "") +
                        (t.about?.let { " · what the user wants: $it" } ?: ""),
                )
            }
            appendLine(
                "Moving on happens at L${s.target}. ${GrowthStore.WINDOW} answers to practice and action cards averaging 3 or more over 4 days unlock a level check; " +
                    "a score of 3 or more on the level check raises the level. Theory answers are reviewed and recalled but do not count toward the level. The app counts; you only score.",
            )
            appendLine()
            if (slots.isEmpty()) appendLine("Today's plan: nothing is in training, so write no cards.")
            else {
                appendLine("Today's plan:")
                slots.forEach { appendLine("- ${it.count} ${it.kind} card(s) for `${it.track.id}` at level ${it.track.level}") }
            }
            s.focus?.let { f ->
                appendLine()
                val units = unitLines(f, posts)
                if (units.isEmpty()) appendLine("Course units of `${f.id}` at L${f.level}: none started yet; begin with the first unit of L${f.level} in its skill.")
                else {
                    appendLine("Course units of `${f.id}` at L${f.level} so far (scores per kind; ? = answered, not reviewed; open = not answered):")
                    units.forEach { appendLine(it) }
                }
                GrowthStore.unanswered(f.id, posts, 7, action = true).takeIf { it.isNotEmpty() }?.let { open ->
                    appendLine("Real-life tasks still waiting for the user's report (set no new one; do not repeat them):")
                    open.forEach { appendLine("- ${it.title}" + (if (it.unit.isNotBlank()) " (${it.unit})" else "") + ", ${(now - it.createdAt) / DAY_MS} day(s) ago") }
                }
            }
            val recent = GrowthStore.recentGraded(8)
            if (recent.isNotEmpty()) {
                appendLine()
                appendLine("Recently reviewed answers (adjust the difficulty, do not repeat a question):")
                recent.forEach {
                    appendLine(
                        "- ${it.track} L${it.level} ${it.kind}" + (if (it.unit.isNotBlank()) " ${it.unit}" else "") + " score ${it.score}" +
                            (it.difficulty?.let { d -> ", felt $d" } ?: "") +
                            ": Q: ${it.prompt.take(100)} | A: ${it.answer.take(120)} | feedback: ${it.feedback.orEmpty().take(120)}",
                    )
                }
                appendLine("When the user marked recent cards too easy or too hard, move the difficulty within the level accordingly.")
            }
            GrowthStore.weakRecall(5).takeIf { it.isNotEmpty() }?.let { weak ->
                appendLine()
                appendLine("Points the user keeps forgetting (work them into today's cards when they fit):")
                weak.forEach { appendLine("- [${it.track}] ${it.question} → ${it.answer.take(120)}") }
            }
            if (pending.isNotEmpty()) {
                appendLine()
                appendLine("Answers waiting for review:")
                pending.forEach {
                    appendLine("- post=${it.post} track=${it.track} level=${it.level} kind=${it.kind}" + (if (it.unit.isNotBlank()) " unit=${it.unit}" else "") +
                        " Q: ${it.prompt.take(200)} | A: ${it.answer.take(800)}")
                }
            }
            val memory = GrowthStore.read(GrowthStore.memoryFile())
            val observations = GrowthStore.observations()
            if (memory.isNotEmpty() || observations.isNotEmpty()) {
                appendLine(); appendLine("Growth memory (how this user learns, kept by you):")
                if (memory.isNotEmpty()) appendLine(memory.take(2500))
                if (observations.isNotEmpty()) { appendLine("Observations since the last summary:"); observations.takeLast(20).forEach { appendLine(it) } }
            }
            GrowthStore.read(GrowthStore.principlesFile()).takeIf { it.isNotEmpty() }?.let {
                appendLine(); appendLine("The user's own principles so far:"); appendLine(it.take(1800))
            }
            // Mosaic: the person's own notes, when they mounted a folder, are material for the cards.
            GrowthSources.folders(context).filter { it.available }.takeIf { it.isNotEmpty() }?.let { folders ->
                appendLine()
                appendLine("The user's own notes, mounted in the sandbox (list and read files there when a card needs material from them; this counts toward the three tool calls):")
                folders.forEach { appendLine("- ${it.linuxPath} (${it.source})") }
            }
            if (needed.isNotEmpty()) {
                appendLine()
                appendLine("## Skills for these abilities (books, course units by level, card kinds, rubric)")
                needed.forEach { t ->
                    appendLine("### ${t.id} (skill `${t.skill}`)")
                    appendLine(
                        skillBody(context, t.skill)?.take(SKILL_CHARS)
                            ?: (skillBody(context, GrowthStore.GENERAL_SKILL)?.take(SKILL_CHARS)?.let { "(its own skill is not written yet; the general method follows)\n$it" })
                            ?: "(skill missing: train ${t.title(context)} with good general practice)",
                    )
                    t.about?.let { appendLine("What the user wants from this ability: $it") }
                }
            }
            // The course behind the ability in training: its book cards, the person's framework and the changes in force.
            s.focus?.let { f ->
                appendLine()
                val books = GrowthStore.bookCards(f.skill)
                if (books.isEmpty()) appendLine(
                    "### Book cards of `${f.id}`: none yet. Teach from the skill's book list and your own knowledge, mark what you are not sure of as unverified, " +
                        "and once, in a card's body, suggest building the course (Build the course, on the abilities sheet).",
                ) else {
                    appendLine("### Book cards of `${f.id}` (/var/minis/skills/${f.skill}/books/): theory cards teach a model from these; put the book id and title in source")
                    var left = BOOK_CHARS
                    books.forEach { (name, text) ->
                        if (left <= 0) return@forEach
                        val part = text.take(minOf(1500, left))
                        appendLine("#### $name"); appendLine(part)
                        left -= part.length
                    }
                }
                appendLine()
                appendLine("### The user's framework for `${f.id}` (FRAMEWORK.md, what they will keep for life)")
                appendLine(GrowthStore.framework(f.skill).take(3500).ifEmpty { "(not started: write it the first time a unit is completed, one heading per sub-skill of the course)" })
                GrowthStore.adjustments(f.skill).takeLast(12).takeIf { it.isNotEmpty() }?.let { adjustments ->
                    appendLine()
                    appendLine("### Course adjustments in force (newest last; where they differ from the course, they win)")
                    adjustments.forEach { appendLine(it) }
                }
            }
            appendLine()
            appendLine("## Formats")
            appendLine(
                "When a message asks you to write the cards: reply with one short line, then (1) one `$GRADE_BLOCK` block for each answer waiting for review, " +
                    "(2) the cards of today's plan, each its own fenced block tagged `${FeedFlow.BLOCK}` with JSON " +
                    "{\"emoji\": \"one emoji\", \"title\": \"<= 30 characters\", \"type\": \"theory|practice|action|challenge|review\", \"track\": \"<ability id>\", \"level\": <its level>, " +
                    "\"unit\": \"the unit as the skill numbers and names it, e.g. 1.2 and its name\", " +
                    "\"body\": \"Markdown; theory: the idea as described above, 4 to 10 sentences; practice: the situation, 2 to 6 sentences; action: the task with its steps and the words to say; never the answer to the prompt\", " +
                    "\"prompt\": \"the one question the user answers, 1 or 2 sentences\", \"source\": [\"the book and its part, or where the material came from\"]}. " +
                    "Write no other kind of post. Say nothing after the last block. " +
                    "A challenge card is the level check: harder than practice at the same level, mixing what the level covers, in a situation the user has not seen. " +
                    "A review card revisits a kept-up ability with a scenario or a small real-life task from its level.",
            )
            if (weeklyDue(posts, now)) appendLine(
                "Today is the weekly report: add one post of type `weekly` (no track, no prompt): what moved this week (levels, units, scores, " +
                    "what the user marked too easy or too hard, the real-life tasks done and what came of them), the one recurring gap, and the one focus for next week, in 4 to 8 lines.",
            )
            appendLine(
                "When a message starts with [GRADE]: reply with one short line and exactly one `$GRADE_BLOCK` block for that post. " +
                    "Format: {\"post\": \"<post id>\", \"score\": 0-4, \"feedback\": \"Markdown in the user's language: what holds, what is missing, one concrete next step. " +
                    "For a practice card add a response plan they can follow (steps and sentences). For an action report compare what happened with the plan, " +
                    "name what worked and what to change, and set the next concrete attempt.\", " +
                    "\"memory\": \"optional: one new line about how this user learns or thinks\", " +
                    "\"takeaway\": {\"q\": \"a question\", \"a\": \"a short answer\"} optional: one point worth remembering from this answer (the idea of a theory card, a corrected English expression, a principle, the key question of a lens), the app brings it back at growing intervals, " +
                    "\"principle\": {\"text\": \"...\", \"category\": \"做人|做事|公司 or similar\", \"from\": \"the event\"} only when the user adopted or rewrote a principle in this answer}. " +
                    "Score with the ability's rubric at the card's level; a blank, evasive or off-topic answer scores 0; do not inflate. " +
                    "An action report is scored on the doing and the reflection, not on whether the other side happened to agree. A challenge card is scored strictly: 3 means the next level is earned.",
            )
            appendLine(
                "When the user's scores or real-world reports show the course should change for them (repeat a unit, add a remedial unit, skip one they already master, " +
                    "bring in another book, change the order), add one `$COURSE_BLOCK` block with JSON {\"track\": \"<ability id>\", \"change\": \"one line: what changes and why\"}. " +
                    "The app keeps these with the course and shows them to you every day.",
            )
            appendLine(
                "Whenever a unit of the ability in training has just been completed (its theory and one practice or action scored 3 or more), and on Sunday, " +
                    "rewrite the user's framework for it: one block whose fence line is ```$FRAMEWORK_BLOCK track=<ability id> and whose content is the whole new FRAMEWORK.md in Markdown. " +
                    "Keep one heading per sub-skill of the course; under each, what the user has learnt: the model (with its book id), their own case from their answers, " +
                    "and the principle or habit they hold now. Keep everything that was there, at most 4000 characters, in the user's language.",
            )
            if (Calendar.getInstance().get(Calendar.DAY_OF_WEEK) == Calendar.SUNDAY || GrowthStore.observationCount() >= 20) {
                appendLine(
                    "Once in this run, also rewrite the growth memory: one `$MEMORY_BLOCK` block holding the full new text (<= 1200 characters, the user's language): " +
                        "how the user learns now, strengths, recurring gaps, what works for them. Fold the observations in.",
                )
            }
        }
    }

    /** The skill as it is on disk now, so an edit by the user or the agent counts at once; front matter dropped. */
    private fun skillBody(context: Context, id: String): String? = runCatching {
        val lines = java.io.File(context.filesDir, "minis-global/skills/$id/SKILL.md").readText().replace("\r\n", "\n").lines()
        val end = if (lines.firstOrNull()?.trim() == "---") lines.drop(1).indexOfFirst { it.trim() == "---" } + 2 else 0
        lines.drop(end).joinToString("\n").trim()
    }.getOrNull()?.takeIf { it.isNotBlank() }

    /** Saves the answer and starts its review. */
    fun submit(context: Context, post: FeedPost, answer: String) {
        val text = answer.trim()
        if (text.isEmpty() || post.track == null) return
        GrowthStore.recordAnswer(post, text)
        review(context, post.id)
    }

    /**
     * One review turn in the coach conversation, after the coach's own run when one is going. A
     * review that cannot run now stays waiting: the next run reviews it, or a tap retries.
     */
    fun review(context: Context, postId: String) {
        if (postId in _grading.value) return
        val response = GrowthStore.responses.value[postId] ?: return
        _grading.update { it + postId }
        scope.launch {
            try {
                val app = context.applicationContext as MinisApp
                FeedFlow.ensureRoutine(app) ?: return@launch
                val session = FeedFlow.sessionId(app) ?: return@launch
                val free = withTimeoutOrNull(180_000L) {
                    while (FeedFlow.generating.value || ScheduledRunScopes.isActive(session) || ChatViewModelStore.isSessionBusy(session)) delay(1000)
                    true
                }
                if (free == null) return@launch
                // The card itself goes along: after a compaction the conversation may no longer hold it.
                val card = FeedStore.posts.value.firstOrNull { it.id == postId }
                val message = buildString {
                    appendLine("[GRADE] post=${response.post} track=${response.track} level=${response.level} kind=${response.kind}" +
                        if (response.unit.isNotBlank()) " unit=${response.unit}" else "")
                    card?.let { appendLine("Card: ${it.title}"); appendLine(it.body.take(1500)) }
                    appendLine("Question: ${response.prompt}")
                    appendLine("Answer:")
                    append(response.answer)
                }
                val result = HeadlessChatRunner.prompt(app, session, message, wait = true, timeoutMs = 180_000L)
                if (result.status != "Completed") AppLogger.warning(TAG, "review of $postId ended ${result.status}")
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (e: Exception) {
                AppLogger.warning(TAG, "review of $postId failed: ${e.message}")
            } finally {
                _grading.update { it - postId }
            }
        }
    }

    /** Reads reviews and the memory rewrite out of a finished turn of the coach conversation. */
    fun afterTurn(text: String) {
        gradeBlock.findAll(text).forEach { m ->
            val o = runCatching { JSONObject(m.groupValues[1].trim()) }.getOrNull() ?: return@forEach
            val post = o.optString("post").trim().ifEmpty { return@forEach }
            val score = if (o.has("score")) o.optInt("score", -1) else -1
            if (score !in 0..4) return@forEach
            val response = GrowthStore.responses.value[post] ?: return@forEach
            if (!GrowthStore.recordGrade(post, score, o.optString("feedback").trim())) return@forEach
            o.optString("memory").trim().takeIf { it.isNotEmpty() }?.let { GrowthStore.observe(response.track, it) }
            o.optJSONObject("takeaway")?.let { GrowthStore.addRecall(response.track, it.optString("q"), it.optString("a")) }
            when (val p = o.opt("principle")) {
                is JSONObject -> p.optString("text").takeIf { it.isNotBlank() }?.let { GrowthStore.addPrinciple(it, p.optString("category"), p.optString("from")) }
                is String -> if (p.isNotBlank()) GrowthStore.addPrinciple(p, null, null)
            }
        }
        memoryBlock.find(text)?.groupValues?.get(1)?.trim()?.takeIf { it.isNotEmpty() }?.let(GrowthStore::replaceMemory)
        val tracks = GrowthStore.state.value.tracks
        courseBlock.findAll(text).forEach { m ->
            val o = runCatching { JSONObject(m.groupValues[1].trim()) }.getOrNull() ?: return@forEach
            val track = tracks.firstOrNull { it.id == o.optString("track").trim() } ?: return@forEach
            o.optString("change").trim().takeIf { it.isNotEmpty() }?.let { GrowthStore.addAdjustment(track.skill, it) }
        }
        frameworkBlock.findAll(text).forEach { m ->
            val track = tracks.firstOrNull { it.id == m.groupValues[1] } ?: return@forEach
            GrowthStore.writeFramework(track.skill, m.groupValues[2])
        }
    }

    // ── talking it over in a chat of its own ──────────────────────────────

    /**
     * The first message of a side chat on a training card: the ability, level and unit, the card,
     * the question, and the person's answer with its review when there is one.
     */
    fun discussOpener(context: Context, post: FeedPost): String {
        val track = GrowthStore.state.value.tracks.firstOrNull { it.id == post.track }
        val levels = context.resources.getStringArray(R.array.nm_growth_levels)
        val response = GrowthStore.responses.value[post.id]
        return buildString {
            appendLine(context.getString(R.string.nm_growth_discuss_intro))
            appendLine()
            track?.let {
                val where = listOf("L${post.level.coerceAtLeast(1)} " + levels.getOrElse(post.level.coerceAtLeast(1) - 1) { "" }, post.unit).filter { s -> s.isNotBlank() }
                appendLine(context.getString(R.string.nm_growth_discuss_where, it.title(context), where.joinToString(" · ")))
                appendLine()
            }
            appendLine("**${post.title}**")
            appendLine()
            appendLine(post.body.take(1500))
            if (post.prompt.isNotBlank()) { appendLine(); appendLine(context.getString(R.string.nm_growth_discuss_question, post.prompt)) }
            response?.let { r ->
                appendLine(); appendLine(context.getString(R.string.nm_growth_discuss_answer, r.answer.take(1500)))
                if (r.score != null) { appendLine(); appendLine(context.getString(R.string.nm_growth_discuss_review, r.score, r.feedback.orEmpty().take(1500))) }
            }
            appendLine()
            append(context.getString(R.string.nm_growth_discuss_ask))
        }
    }

    /** The skill an ability's own course is written under. */
    fun courseSkill(trackId: String): String = "growth-$trackId"

    /**
     * The first message of the chat that builds (or rebuilds) an ability's course with whatever model
     * the chat runs on, following the course framework skill (`growth-course-builder`): the ability,
     * what the person wants from it, its course folder and their record so far. An ability trained by
     * the general method points at a course of its own from now on; until the agent has written it,
     * the general method goes on training it.
     */
    fun buildOpener(context: Context, trackId: String): String? {
        val track = GrowthStore.state.value.tracks.firstOrNull { it.id == trackId } ?: return null
        val skill = if (track.skill == GrowthStore.GENERAL_SKILL) courseSkill(track.id).also { GrowthStore.setSkill(track.id, it) } else track.skill
        val title = track.title(context)
        val levels = context.resources.getStringArray(R.array.nm_growth_levels)
        val answers = GrowthStore.responses.value.values.count { it.track == track.id }
        val record = context.getString(R.string.nm_growth_build_record, "L${track.level} " + levels.getOrElse(track.level - 1) { "" }, answers,
            track.scores.takeLast(GrowthStore.WINDOW).joinToString(", ").ifEmpty { "-" })
        val memory = GrowthStore.read(GrowthStore.memoryFile()).take(600)
        return context.getString(R.string.nm_growth_build_opener, title, track.about?.takeIf { it.isNotBlank() } ?: title, "/var/minis/skills/$skill/", skill,
            if (memory.isEmpty()) record else record + " " + context.getString(R.string.nm_growth_build_memory, memory))
    }
}
