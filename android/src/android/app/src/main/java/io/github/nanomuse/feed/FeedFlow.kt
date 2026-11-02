package io.github.nanomuse.feed

import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.net.Uri
import androidx.core.app.NotificationCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.ProcessLifecycleOwner
import com.openminis.app.MinisApp
import com.openminis.app.R
import com.openminis.app.logging.AppLogger
import com.openminis.app.scheduled.ScheduledAgentRunner
import com.openminis.app.scheduled.ScheduledRepeatMode
import com.openminis.app.scheduled.ScheduledTargetMode
import com.openminis.app.scheduled.ScheduledTask
import com.openminis.app.scheduled.ScheduledTaskManager
import io.github.nanomuse.deeplink.OwnScheme
import io.github.nanomuse.goals.GoalSessions
import io.github.nanomuse.goals.GoalStore
import io.github.nanomuse.identity.NanoMuseIdentity
import io.github.nanomuse.sysfiles.SystemFiles
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale

/**
 * How the Coach tab's training cards get written (it began as Muse's feed, hence the names): one
 * built-in routine (a plain scheduled task the user can switch off or re-time), which sends a
 * one-line prompt into the coach's own conversation.
 * That conversation's system prompt carries the user's feed preferences and a digest of what the
 * agent knows (GLOBAL.md, the last seven days of diary, USER.md, goals); the model answers with
 * `nanomuse-feed` blocks, which the app turns into files under `feed/YYYY-MM-DD/` and into cards.
 *
 * The conversation is the agent's workbench, not a chat of the person's: it is kept out of the
 * drawer, the chat list, the search and the main-chat fallback ([hidden]), the posts show in the
 * Feed tab, and when a run wrote something while the app was in the background, one notification
 * says so and opens the Feed ([notifyIfFeed]).
 */
object FeedFlow {
    private const val TAG = "Feed"
    private const val PREFS = "nanomuse"
    private const val KEY_TASK = "feed.task"
    private const val KEY_SESSION = "feed.session"
    private const val KEY_FIRST_DAY = "feed.first_day"
    const val BLOCK = "nanomuse-feed"
    const val DEFAULT_HOUR = 8
    const val DEFAULT_MINUTE = 0
    private const val NOTIFICATION_ID = 0x6E6D_4645 // "nmFE"

    private val block = Regex("```$BLOCK[ \\t]*\\r?\\n([\\s\\S]*?)```")
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    private val _generating = MutableStateFlow(false)
    val generating: StateFlow<Boolean> = _generating

    private val _writeFailure = MutableStateFlow<String?>(null)
    /** Mosaic: why the last "Write them now" wrote no card, in the user's words; null once a run wrote some. */
    val writeFailure: StateFlow<String?> = _writeFailure

    private val _hidden = MutableStateFlow<Set<String>>(emptySet())
    /** The feed's working conversation, which no list shows (`ChatRepository.observeSessions`, `MainChat`). */
    val hidden: StateFlow<Set<String>> = _hidden

    /** Titles the last feed run wrote, for the notification; cleared once told. */
    @Volatile private var lastWritten: List<String> = emptyList()
    @Volatile private var lastWrittenAt = 0L

    fun init(context: Context) {
        FeedStore.init(context)
        io.github.nanomuse.growth.GrowthStore.init(context) // Mosaic: the growth record behind the feed
        publishSession(prefs(context).getString(KEY_SESSION, null))
        scope.launch { runCatching { ensureRoutine(context) }.onFailure { AppLogger.warning(TAG, "ensure failed: ${it.message}") } }
    }

    /** Another account's preferences and routine are in place (contract C12): read them again. */
    fun refresh(context: Context) {
        io.github.nanomuse.growth.GrowthStore.reload() // Mosaic
        _writeFailure.value = null
        publishSession(prefs(context).getString(KEY_SESSION, null))
        scope.launch { runCatching { ensureRoutine(context) }.onFailure { AppLogger.warning(TAG, "ensure failed: ${it.message}") } }
    }

    private fun publishSession(id: String?) {
        _hidden.value = if (id.isNullOrEmpty()) emptySet() else setOf(id)
    }

    private fun prefs(context: Context) = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    fun taskId(context: Context): String? = prefs(context).getString(KEY_TASK, null)
    fun sessionId(context: Context): String? = prefs(context).getString(KEY_SESSION, null)
    fun task(context: Context): ScheduledTask? = taskId(context)?.let { ScheduledTaskManager(context).get(it) }
    fun isFeedSession(context: Context, sessionId: String): Boolean = sessionId.isNotEmpty() && sessionId == sessionId(context)

    /**
     * Makes sure the routine and its conversation exist. Needs a configured model to create the
     * conversation; until then it quietly does nothing and is retried on the next launch and
     * whenever the Feed tab shows. A conversation the user deleted is recreated and re-bound.
     */
    suspend fun ensureRoutine(context: Context): ScheduledTask? {
        val app = context.applicationContext as? MinisApp ?: return null
        if (!app.subsystemsReady()) return null
        val manager = ScheduledTaskManager(app)
        val p = prefs(app)
        var sessionId = p.getString(KEY_SESSION, null)
        if (sessionId != null && withContext(Dispatchers.IO) { app.chatRepository.getSession(sessionId!!) } == null) sessionId = null
        if (sessionId == null) {
            sessionId = GoalSessions.create(app, app.getString(R.string.nm_growth_session_title)) ?: return null
            p.edit().putString(KEY_SESSION, sessionId).apply()
        }
        publishSession(sessionId)
        val existing = p.getString(KEY_TASK, null)?.let { manager.get(it) }
        // Mosaic: the routine asks for training cards; a routine made by an older build is brought up to date, its time and switch kept.
        val prompt = app.getString(R.string.nm_growth_prompt)
        val label = app.getString(R.string.nm_growth_routine_label)
        return if (existing == null) {
            val task = manager.create(
                ScheduledTask(
                    label = label,
                    timeOfDayHour = DEFAULT_HOUR,
                    timeOfDayMinute = DEFAULT_MINUTE,
                    repeatMode = ScheduledRepeatMode.DAILY,
                    prompt = prompt,
                    targetMode = ScheduledTargetMode.AppendToSession(sessionId),
                    origin = "builtin_feed", // nanoMuse: 内置动态不归入用户定时任务组。
                ),
            )
            p.edit().putString(KEY_TASK, task.id).apply()
            AppLogger.info(TAG, "feed routine created: task=${task.id} session=$sessionId")
            task
        } else if (existing.targetMode.sessionIdOrNull != sessionId || existing.prompt != prompt || existing.label != label) {
            manager.update(existing.copy(targetMode = ScheduledTargetMode.AppendToSession(sessionId), prompt = prompt, label = label))
        } else existing
    }

    /** Runs the routine right now (the "Write it now" button). */
    fun generateNow(context: Context) = writeNow(context) {}

    /**
     * The first feed day, written on its own right after the first conversation ends (the
     * agent has its name, so a model is there to answer). Once per install: the flag is set
     * when the run is actually dispatched, so a phone without a model yet gets it later.
     */
    fun writeFirstDay(context: Context) {
        val p = prefs(context)
        if (p.getBoolean(KEY_FIRST_DAY, false)) return
        if (io.github.nanomuse.growth.GrowthFlow.plan(FeedStore.posts.value).isEmpty()) return // Mosaic: nothing to train yet, so nothing to say on the page
        writeNow(context) { p.edit().putBoolean(KEY_FIRST_DAY, true).apply() }
    }

    private fun writeNow(context: Context, onDispatch: () -> Unit) {
        if (_generating.value) return
        scope.launch {
            _generating.value = true
            _writeFailure.value = null
            val app = context.applicationContext
            // Mosaic: a run that writes no card says why on the page instead of ending in silence.
            fun fail(why: String) {
                AppLogger.warning(TAG, "no cards written: $why")
                _writeFailure.value = app.getString(R.string.nm_growth_write_failed, why)
            }
            try {
                if (io.github.nanomuse.growth.GrowthFlow.plan(FeedStore.posts.value).isEmpty()) return@launch fail(app.getString(R.string.nm_growth_fail_nothing))
                val task = runCatching { ensureRoutine(context) }.getOrNull() ?: return@launch fail(app.getString(R.string.nm_growth_fail_no_model))
                val session = sessionId(app)
                if (session != null && (io.github.nanomuse.growth.GrowthFlow.grading.value.isNotEmpty() ||
                        io.github.nanomuse.routines.ScheduledRunScopes.isActive(session) || com.openminis.app.ui.chat.ChatViewModelStore.isSessionBusy(session))
                ) return@launch fail(app.getString(R.string.nm_growth_fail_busy))
                onDispatch()
                val started = System.currentTimeMillis()
                var outcome: io.github.nanomuse.routines.ScheduledCompletion? = null
                ScheduledAgentRunner.run(app, task, waitForCompletion = true, onResult = { outcome = it })
                if (lastWrittenAt >= started) return@launch
                if (outcome?.outcome == io.github.nanomuse.routines.RunOutcome.FAILURE) {
                    // The model's own error (the chat shows it under the turn) says the most; the run record is the fallback.
                    val error = session?.let { id ->
                        withContext(Dispatchers.Main) { com.openminis.app.ui.chat.ChatViewModelStore.existingViewModel(id)?.error?.value }
                    }?.trim()?.take(120)?.ifBlank { null }
                    val detail = error ?: ScheduledTaskManager(app).get(task.id)?.runHistory?.firstOrNull()?.preview?.trim()
                        ?.takeUnless { it.isBlank() || it == "(no response)" }?.take(120)
                    fail(app.getString(R.string.nm_growth_fail_run, detail ?: outcome?.status.orEmpty()))
                } else fail(app.getString(R.string.nm_growth_fail_no_cards))
            } finally {
                _generating.value = false
            }
        }
    }

    fun setEnabled(context: Context, enabled: Boolean) {
        val id = taskId(context) ?: return
        ScheduledTaskManager(context).setEnabled(id, enabled)
    }

    /** Called after every completed turn: `nanomuse-feed` blocks become posts. */
    fun afterTurn(context: Context, sessionId: String, assistantText: String?) {
        if (assistantText.isNullOrEmpty()) return
        // Mosaic: reviews and the growth memory come only from the feed's own conversation.
        if (isFeedSession(context, sessionId)) io.github.nanomuse.growth.GrowthFlow.afterTurn(assistantText)
        if (!assistantText.contains("```$BLOCK")) return
        val today = FeedStore.posts.value.filter { it.day == SimpleDateFormat("yyyy-MM-dd", Locale.US).format(Date()) }
        val drafts = block.findAll(assistantText).mapNotNull { m -> parseDraft(m.groupValues[1]) }
            .filter { d -> today.none { it.title.equals(d.title.trim().take(80), ignoreCase = true) } }
            .toList()
        if (drafts.isEmpty()) return
        val written = FeedStore.append(drafts)
        io.github.nanomuse.growth.GrowthStore.cardsWritten(written) // Mosaic: the ability's review clock restarts
        if (written.isNotEmpty() && isFeedSession(context, sessionId)) {
            AppLogger.info(TAG, "feed run in $sessionId wrote ${written.size} post(s)")
            lastWritten = written.map { it.title }
            lastWrittenAt = System.currentTimeMillis()
            _writeFailure.value = null
        }
    }

    /**
     * The scheduled runner finished [task]: when it is the feed's routine, this takes the
     * completion notice over (true), so the generic "task done" with the model's raw reply never
     * shows. With the app on screen the Feed tab already shows the posts; in the background, and
     * only when the run wrote something, one notification names them and opens the Feed.
     */
    fun notifyIfFeed(context: Context, task: ScheduledTask): Boolean {
        if (task.id != taskId(context)) return false
        val titles = lastWritten.takeIf { it.isNotEmpty() && System.currentTimeMillis() - lastWrittenAt < 30 * 60_000L } ?: return true
        lastWritten = emptyList()
        if (ProcessLifecycleOwner.get().lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED)) return true
        val body = titles.take(3).joinToString(" · ")
        val open = OwnScheme.intent(context, Uri.parse("minis://feed"), flags = 0)
        val pending = PendingIntent.getActivity(
            context,
            NOTIFICATION_ID,
            open,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val notification = NotificationCompat.Builder(context, ScheduledTaskManager.CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_nanomuse)
            .setLargeIcon(NanoMuseIdentity.face(context))
            .setContentTitle("${NanoMuseIdentity.name(context)}: ${context.getString(R.string.nm_growth_session_title)}")
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setContentIntent(pending)
            .setAutoCancel(true)
            .setPriority(NotificationCompat.PRIORITY_DEFAULT)
            .build()
        try {
            (context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).notify(NOTIFICATION_ID, notification)
        } catch (_: SecurityException) {
            AppLogger.warning(TAG, "POST_NOTIFICATIONS denied; the feed's notice was not shown")
        }
        return true
    }

    private fun parseDraft(json: String): FeedStore.Draft? {
        val o = runCatching { JSONObject(json.trim()) }.getOrNull() ?: return null
        val title = o.optString("title").trim().ifEmpty { return null }
        val body = o.optString("body").trim().ifEmpty { return null }
        val source = when (val s = o.opt("source")) {
            is JSONArray -> List(s.length()) { s.optString(it).trim() }.filter { it.isNotEmpty() }
            is String -> s.split(";", ",").map { it.trim() }.filter { it.isNotEmpty() }
            else -> emptyList()
        }
        if (!isCoachCard(o)) return null
        val track = trackOf(o)
        val type = typeOf(o)
        val prompt = if (track != null) o.optString("prompt").trim().take(400) else ""
        return FeedStore.Draft(title = title, type = type, emoji = o.optString("emoji").trim().take(4), body = body, source = source.take(4),
            track = track?.id, level = if (track != null) o.optInt("level", track.level).coerceIn(1, 5) else 0, prompt = prompt,
            unit = if (track != null) o.optString("unit").trim().take(60) else "")
    }

    // Mosaic: the page coaches, so only training cards and the weekly report exist; the feed's post kinds are gone.
    val TYPES = setOf("theory", "practice", "challenge", "review", "action", "weekly")

    private fun trackOf(o: JSONObject) = io.github.nanomuse.growth.GrowthStore.state.value.tracks.firstOrNull { it.id == o.optString("track").trim() }
    private fun typeOf(o: JSONObject) = o.optString("type").trim().lowercase().takeIf { it in TYPES } ?: "practice"

    /**
     * Mosaic: whether a `nanomuse-feed` block becomes a card. A card counts only for an ability the
     * growth record knows; apart from the weekly report, a post without one (news, a paper digest,
     * any general post) is dropped. The chat shows "Added to Coach" only for what passes.
     */
    fun isCoachCard(o: JSONObject): Boolean = trackOf(o) != null || typeOf(o) == "weekly"

    /** Mosaic: the coach page shows training cards and the weekly report; posts an older feed wrote are left on disk, unshown. */
    fun isCoachPost(post: FeedPost): Boolean = post.type in TYPES && (post.track != null || post.type == "weekly")

    /** Appended to the system prompt of the feed's conversation (null elsewhere). */
    fun systemAddendum(context: Context, sessionId: String): String? {
        if (!isFeedSession(context, sessionId)) return null
        val digest = digest(context)
        val recent = FeedStore.posts.value.take(24).map { it.title }
        return buildString {
            appendLine("## This conversation writes the user's training cards (Nicholasx)")
            appendLine("The Coach tab shows the training cards you write: today's on the page, earlier days in its calendar. The user's standing instruction for it (it steers what the cards draw on and stress, never what kind of card you write):")
            appendLine("> " + FeedStore.preferences.value.replace("\n", "\n> "))
            appendLine()
            appendLine("What you know about them right now (from GLOBAL.md, the diary of the last seven days, USER.md and their goals):")
            appendLine(digest.ifBlank { "(nothing recorded yet: start at the lowest level and ask about their life in the first cards)" })
            appendLine()
            // Mosaic: the feed trains abilities; the plan, the skills, the answers and the formats come from the growth record.
            appendLine(io.github.nanomuse.growth.GrowthFlow.section(context, FeedStore.posts.value))
            appendLine(
                "Write in the user's language; be concrete; no clickbait, no filler, nothing you already posted. " +
                    "Use tools only when a card needs a live fact or the user's diary and habits (`minis-jigsaw-cli`), at most three quick calls.",
            )
            if (recent.isNotEmpty()) appendLine("Recent titles (do not repeat): ${recent.joinToString(" · ")}")
            appendLine("In ordinary conversation here, answer normally; add a `$BLOCK` block only when the user asks for a training card.")
        }
    }

    /** Bounded digest of the agent's memory and the user's goals. */
    private fun digest(context: Context): String {
        val memoryDir = File(context.filesDir, "minis-global/memory")
        val sb = StringBuilder()
        fun add(label: String, text: String?, limit: Int) {
            val t = text?.trim().orEmpty()
            if (t.isEmpty()) return
            sb.appendLine("### $label").appendLine(if (t.length > limit) t.take(limit) + " …" else t)
        }
        add("USER.md", runCatching { SystemFiles.USER.file(context).takeIf { it.exists() }?.readText() }.getOrNull(), 1500)
        add("GLOBAL.md", runCatching { File(memoryDir, "GLOBAL.md").takeIf { it.exists() }?.readText() }.getOrNull(), 2500)
        val fmt = SimpleDateFormat("yyyy-MM-dd", Locale.US)
        val cal = Calendar.getInstance()
        for (i in 0 until 7) {
            val name = fmt.format(cal.time) + ".md"
            val f = File(memoryDir, name)
            if (f.exists()) add("Diary $name", runCatching { f.readText() }.getOrNull(), if (i == 0) 1500 else 600)
            cal.add(Calendar.DAY_OF_YEAR, -1)
        }
        val goals = runCatching { GoalStore.get(context).all() }.getOrDefault(emptyList())
        if (goals.isNotEmpty()) {
            sb.appendLine("### Goals")
            goals.forEach { g -> sb.appendLine("- ${g.title} — ${g.status.name.lowercase()}, ${g.progress}%" + (g.lastNote?.let { "; last: $it" } ?: "")) }
        }
        return sb.toString().take(7000)
    }
}
