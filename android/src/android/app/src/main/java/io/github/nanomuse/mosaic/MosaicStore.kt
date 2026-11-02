package io.github.nanomuse.mosaic

import android.content.Context
import android.graphics.BitmapFactory
import androidx.room.withTransaction
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.withContext
import java.io.File
import java.io.IOException
import java.security.MessageDigest
import java.time.LocalDate
import java.time.ZoneId
import java.util.Locale
import java.util.UUID

/** Why a save did not happen; the editor keeps everything and says which one. */
class MosaicSaveException(val reason: Reason, cause: Throwable? = null) : Exception(reason.name, cause) {
    enum class Reason { EMPTY, FUTURE, PHOTO_MISSING, STORAGE, DATABASE }
}

/**
 * The one way in and out of Mosaic's records. A save is: copy the draft's photo into the archive,
 * then one transaction for the media row, the entry, the habit's done mark and the day's mood, and
 * only then is the draft gone. A failure on the way leaves the draft as it was.
 */
class MosaicStore private constructor(context: Context) {
    private val db = MosaicDatabase.get(context)
    private val dao = db.dao()
    private val mediaDir = File(context.filesDir, "mosaic/media")

    /** Imported photos waiting in drafts; private to the app like the archive. */
    val draftsDir = File(context.filesDir, "mosaic/drafts")

    fun mediaFile(path: String): File = File(mediaDir, path)

    /** 提供日期选择器的轻量记录计数，不读取图片和正文。 */
    fun recordCounts(range: MosaicRange): Flow<List<MosaicRecordCount>> = dao.observeRecordCounts(range.startDay, range.endDay)

    fun period(range: MosaicRange): Flow<MosaicPeriod> = combine(
        dao.observeEntries(range.startDay, range.endDay),
        dao.observeHabitDays(range.startDay, range.endDay),
        dao.observeDays(range.startDay, range.endDay),
        dao.observeHabits(),
        dao.observeSchedules(),
    ) { entries, habitDays, days, habits, schedules ->
        MosaicPeriod(range, entries, habitDays, days, habits, schedules)
    }

    fun drafts(day: Long): Flow<List<MosaicDraft>> = dao.observeDrafts(day)

    suspend fun entryRow(id: String): MosaicEntryRow? = dao.entryRow(id)

    suspend fun habit(id: String): MosaicHabit? = dao.habit(id)

    suspend fun dayInfo(day: Long): MosaicDayInfo? = dao.dayInfo(day)

    suspend fun habitDone(habitId: String, day: Long): Boolean = dao.habitDay(habitId, day)?.state == HabitState.DONE

    // ── Drafts ───────────────────────────────────────────────────────

    suspend fun draft(id: String): MosaicDraft? = dao.draft(id)

    suspend fun putDraft(draft: MosaicDraft) = dao.upsertDraft(draft)

    suspend fun discardDraft(draft: MosaicDraft) {
        dao.deleteDraft(draft.id)
        draft.stagedPath?.let { path -> withContext(Dispatchers.IO) { File(path).delete() } }
    }

    // ── Records ──────────────────────────────────────────────────────

    /**
     * Saves [draft] as a record and returns it, or null when the draft only marked its habit done.
     * Saving the same draft twice returns the first save's entry instead of a second one.
     */
    suspend fun save(draft: MosaicDraft, today: LocalDate): MosaicEntry? = withContext(Dispatchers.IO) {
        val text = draft.text.trim()
        val hasPhoto = draft.stagedPath != null || draft.mediaId != null
        val marksHabit = draft.markDone && draft.habitId != null
        val existing = draft.entryId?.let { dao.entry(it) }
        // A record kept on its own day stays editable after a trip west puts that day ahead of the clock.
        if (draft.day > today.toEpochDay() && existing?.day != draft.day) throw MosaicSaveException(MosaicSaveException.Reason.FUTURE)
        if (text.isEmpty() && !hasPhoto && draft.entryId == null) {
            if (!marksHabit) throw MosaicSaveException(MosaicSaveException.Reason.EMPTY)
            val now = System.currentTimeMillis()
            db.withTransaction {
                dao.upsertHabitDay(MosaicHabitDay(draft.habitId!!, draft.day, HabitState.DONE, now))
                writeMood(draft, now)
                dao.deleteDraft(draft.id)
            }
            return@withContext null
        }
        if (text.isEmpty() && !hasPhoto) throw MosaicSaveException(MosaicSaveException.Reason.EMPTY)
        if (draft.entryId == null) {
            dao.entryByMutation(draft.mutationId)?.let { saved ->
                dao.deleteDraft(draft.id)
                return@withContext saved
            }
        }

        val now = System.currentTimeMillis()
        val staged = draft.stagedPath?.let(::File)
        var archived: File? = null
        val media = staged?.let { source ->
            if (!source.exists()) throw MosaicSaveException(MosaicSaveException.Reason.PHOTO_MISSING)
            val id = UUID.randomUUID().toString()
            val date = LocalDate.ofEpochDay(draft.day)
            val relative = String.format(Locale.ROOT, "%04d/%02d/%s.jpg", date.year, date.monthValue, id)
            val target = File(mediaDir, relative)
            try {
                copyDurably(source, target)
            } catch (e: IOException) {
                throw MosaicSaveException(MosaicSaveException.Reason.STORAGE, e)
            }
            archived = target
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeFile(target.path, bounds)
            MosaicMediaAsset(id, relative, "image/jpeg", bounds.outWidth, bounds.outHeight, target.length(), sha256(target), now)
        }

        val habit = draft.habitId?.let { dao.habit(it) }
        val entry = MosaicEntry(
            id = existing?.id ?: UUID.randomUUID().toString(),
            day = draft.day,
            zoneId = existing?.zoneId ?: ZoneId.systemDefault().id,
            createdAt = existing?.createdAt ?: now,
            updatedAt = now,
            habitId = draft.habitId,
            habitTitle = habit?.title ?: existing?.habitTitle,
            text = text,
            mediaId = media?.id ?: draft.mediaId,
            shape = draft.shape,
            focusX = draft.focusX,
            focusY = draft.focusY,
            zoom = draft.zoom,
            deletedAt = null,
            mutationId = existing?.mutationId ?: draft.mutationId,
            mood = when (draft.mood) {
                null -> existing?.mood
                MOOD_CLEARED -> null
                else -> draft.mood
            },
        )
        try {
            db.withTransaction {
                media?.let { dao.insertMedia(it) }
                dao.upsertEntry(entry)
                if (marksHabit) {
                    dao.upsertHabitDay(MosaicHabitDay(draft.habitId!!, draft.day, HabitState.DONE, now))
                } else if (existing != null && draft.habitId != null && dao.habitDay(draft.habitId, draft.day)?.state == HabitState.DONE) {
                    // Unticked while editing: the habit is no longer done that day.
                    dao.clearHabitDay(draft.habitId, draft.day)
                }
                writeMood(draft, now)
                // A record moved to another day stops being the old day's cover, and takes its habit's mark
                // along unless another record for that habit is still there.
                if (existing != null && existing.day != draft.day) {
                    val old = dao.dayInfo(existing.day)
                    if (old != null && old.coverEntryId == existing.id) dao.upsertDay(old.copy(coverEntryId = null, updatedAt = now))
                    val oldHabit = existing.habitId
                    if (oldHabit != null && dao.habitEntriesOn(oldHabit, existing.day, existing.id) == 0) {
                        dao.clearHabitDay(oldHabit, existing.day)
                    }
                }
                dao.deleteDraft(draft.id)
            }
        } catch (e: Exception) {
            if (e is CancellationException) throw e
            archived?.delete()
            throw MosaicSaveException(MosaicSaveException.Reason.DATABASE, e)
        }
        staged?.delete()
        entry
    }

    /**
     * The day's mood, written only when the person chose one in the editor ([MOOD_CLEARED] clears it):
     * the last mood given that day. Each record keeps its own in [MosaicEntry.mood].
     */
    private suspend fun writeMood(draft: MosaicDraft, now: Long) {
        val chosen = draft.mood ?: return
        val mood = chosen.takeIf { it != MOOD_CLEARED }
        val info = dao.dayInfo(draft.day)
        if (mood != info?.mood) dao.upsertDay((info ?: MosaicDayInfo(day = draft.day, updatedAt = now)).copy(mood = mood, updatedAt = now))
    }

    /**
     * A new record's draft follows its date: it takes the id of the new day's target, or one beside
     * it when that target already holds a draft of its own, so neither is overwritten.
     */
    suspend fun redate(draft: MosaicDraft, day: Long): MosaicDraft = db.withTransaction {
        if (draft.entryId != null) return@withTransaction draft.copy(day = day)
        val target = draftId(day, draft.habitId, null)
        val id = if (target == draft.id || dao.draft(target) == null) target else "$target:${UUID.randomUUID()}"
        val moved = draft.copy(id = id, day = day, updatedAt = System.currentTimeMillis())
        if (dao.draft(draft.id) != null) {
            dao.deleteDraft(draft.id)
            dao.upsertDraft(moved)
        }
        moved
    }

    /** Moves an entry to the bin; [restore] brings it back, and [sweep] empties the bin after a week. */
    suspend fun delete(entryId: String) {
        dao.softDelete(entryId, System.currentTimeMillis())
        // Unsaved edits of a deleted record would bring it back on save.
        dao.draft(draftId(0, null, entryId))?.let { discardDraft(it) }
    }

    suspend fun restore(entryId: String) = dao.restore(entryId, System.currentTimeMillis())

    suspend fun setCover(day: Long, entryId: String?) = db.withTransaction {
        val now = System.currentTimeMillis()
        val info = dao.dayInfo(day) ?: MosaicDayInfo(day = day, updatedAt = now)
        dao.upsertDay(info.copy(coverEntryId = entryId, updatedAt = now))
    }

    /** The shape the person picked for [day]; null goes back to the automatic one. */
    suspend fun setForm(day: Long, form: MosaicForm?) = db.withTransaction {
        val now = System.currentTimeMillis()
        val info = dao.dayInfo(day) ?: MosaicDayInfo(day = day, updatedAt = now)
        dao.upsertDay(info.copy(form = form?.id, updatedAt = now))
    }

    /** Marks a habit done or skipped on [day], or clears the mark ([state] null). Days ahead are refused. */
    suspend fun setHabitState(habitId: String, day: Long, state: String?, today: LocalDate): Boolean {
        if (day > today.toEpochDay()) return false
        if (state == null) dao.clearHabitDay(habitId, day)
        else dao.upsertHabitDay(MosaicHabitDay(habitId, day, state, System.currentTimeMillis()))
        return true
    }

    // ── Habits ───────────────────────────────────────────────────────

    suspend fun addHabit(title: String, shape: MosaicShape, weekdays: Int, today: LocalDate) {
        val now = System.currentTimeMillis()
        db.withTransaction {
            val habit = MosaicHabit(UUID.randomUUID().toString(), title.trim(), shape.id, dao.maxHabitOrder() + 1, now, now)
            dao.upsertHabit(habit)
            dao.upsertSchedule(MosaicHabitSchedule(habit.id, today.toEpochDay(), weekdays))
        }
    }

    /**
     * Renames or reshapes a habit; new [weekdays] take effect from today, earlier days keep their plan.
     * Null leaves the plan alone, so a rename does not end a pause.
     */
    suspend fun updateHabit(habit: MosaicHabit, title: String, shape: MosaicShape, weekdays: Int?, today: LocalDate) {
        val now = System.currentTimeMillis()
        db.withTransaction {
            dao.upsertHabit(habit.copy(title = title.trim(), shape = shape.id, updatedAt = now))
            if (weekdays == null) return@withTransaction
            val current = dao.schedulesOf(habit.id).lastOrNull { it.fromDay <= today.toEpochDay() }
            if (current?.weekdays != weekdays) dao.upsertSchedule(MosaicHabitSchedule(habit.id, today.toEpochDay(), weekdays))
        }
    }

    /** A pause is a plan with no days from today on; resuming brings back the last plan that had some. */
    suspend fun setPaused(habit: MosaicHabit, paused: Boolean, today: LocalDate) {
        val days = if (paused) 0 else {
            dao.schedulesOf(habit.id).lastOrNull { it.weekdays != 0 }?.weekdays ?: MosaicPeriod.EVERY_DAY
        }
        dao.upsertSchedule(MosaicHabitSchedule(habit.id, today.toEpochDay(), days))
    }

    /** From today on the habit has no slot; its records and marks stay where they are. */
    suspend fun archive(habit: MosaicHabit, today: LocalDate) {
        dao.upsertHabit(habit.copy(archivedDay = today.toEpochDay(), updatedAt = System.currentTimeMillis()))
    }

    // ── Housekeeping ─────────────────────────────────────────────────

    /**
     * Empties the bin of entries deleted more than a week ago, and removes files nothing points at:
     * archive copies of a save that died before its commit, photos only a purged entry used, staged
     * photos of discarded drafts. Each waits out a day's grace first, so a save in flight is never
     * cut under.
     */
    suspend fun sweep() = withContext(Dispatchers.IO) {
        val now = System.currentTimeMillis()
        dao.purgeDeleted(now - BIN_MS)
        val orphans = dao.orphanMedia(now - GRACE_MS)
        if (orphans.isNotEmpty()) {
            orphans.forEach { File(mediaDir, it.path).delete() }
            dao.deleteMedia(orphans.map { it.id })
        }
        val known = dao.mediaPaths().toSet()
        mediaDir.walkTopDown()
            .filter { it.isFile && now - it.lastModified() > GRACE_MS }
            .filter { it.relativeTo(mediaDir).invariantSeparatorsPath !in known }
            .forEach { it.delete() }
        val staged = dao.stagedPaths().toSet()
        draftsDir.listFiles()
            ?.filter { it.isFile && it.absolutePath !in staged && now - it.lastModified() > GRACE_MS }
            ?.forEach { it.delete() }
        Unit
    }

    private fun copyDurably(source: File, target: File) {
        val dir = target.parentFile ?: throw IOException("no parent for $target")
        if (!dir.isDirectory && !dir.mkdirs()) throw IOException("cannot create $dir")
        val tmp = File(dir, target.name + ".tmp")
        source.inputStream().use { input ->
            tmp.outputStream().use { output ->
                input.copyTo(output)
                output.fd.sync()
            }
        }
        if (!tmp.renameTo(target)) {
            tmp.delete()
            throw IOException("rename to $target failed")
        }
    }

    private fun sha256(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buffer = ByteArray(64 * 1024)
            while (true) {
                val read = input.read(buffer)
                if (read < 0) break
                digest.update(buffer, 0, read)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }

    companion object {
        @Volatile private var instance: MosaicStore? = null

        fun get(context: Context): MosaicStore = instance ?: synchronized(this) {
            instance ?: MosaicStore(context.applicationContext).also { instance = it }
        }

        /** The draft that belongs to one target: an existing entry, or a habit's slot (or a free record) on a day. */
        fun draftId(day: Long, habitId: String?, entryId: String?): String =
            if (entryId != null) "entry:$entryId" else "day:$day:${habitId ?: "free"}"

        /** A draft's [MosaicDraft.mood] when the person chose "no mood" for a day that had one. */
        const val MOOD_CLEARED = 0

        private const val BIN_MS = 7L * 24 * 60 * 60 * 1000
        private const val GRACE_MS = 24L * 60 * 60 * 1000
    }
}
