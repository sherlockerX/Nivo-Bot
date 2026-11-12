package io.github.nanomuse.mosaic

import android.content.Context
import androidx.room.Dao
import androidx.room.Database
import androidx.room.Embedded
import androidx.room.Entity
import androidx.room.Index
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.PrimaryKey
import androidx.room.Query
import androidx.room.Room
import androidx.room.RoomDatabase
import androidx.room.Upsert
import androidx.room.migration.Migration
import androidx.sqlite.db.SupportSQLiteDatabase
import kotlinx.coroutines.flow.Flow

/**
 * Mosaic's facts, in a database of their own (`mosaic.db`) so its migrations never ride on the
 * chat database's. Days are `LocalDate.toEpochDay()`: the calendar day the person chose, not a
 * timestamp divided by 86400. Photos live as files under `filesDir/mosaic/media`; rows point at
 * them by relative path.
 */

/** A habit: its name, the shape its slot takes, its place in the list. When it is planned lives in [MosaicHabitSchedule]. */
@Entity(tableName = "habits")
data class MosaicHabit(
    @PrimaryKey val id: String,
    val title: String,
    val shape: String,
    val sortOrder: Int,
    val createdAt: Long,
    val updatedAt: Long,
    /** The first day the habit no longer gets a slot; null while it is in use. */
    val archivedDay: Long? = null,
)

/**
 * One version of a habit's plan, in force from [fromDay] until the next version. [weekdays] is a
 * bit set, bit 0 Monday to bit 6 Sunday; 0 is a pause. A change adds a version and never rewrites
 * an older one, so past days keep the plan they had.
 */
@Entity(tableName = "habit_schedules", primaryKeys = ["habitId", "fromDay"])
data class MosaicHabitSchedule(
    val habitId: String,
    val fromDay: Long,
    val weekdays: Int,
)

/** A habit's state on one day, [HabitState.DONE] or [HabitState.SKIPPED]; not marked is no row at all. */
@Entity(tableName = "habit_days", primaryKeys = ["habitId", "day"], indices = [Index("day")])
data class MosaicHabitDay(
    val habitId: String,
    val day: Long,
    val state: String,
    val updatedAt: Long,
)

object HabitState {
    const val DONE = "done"
    const val SKIPPED = "skipped"
}

/** One record: a photo, a sentence, or both, on one day, optionally for one habit. */
@Entity(
    tableName = "entries",
    indices = [Index("day"), Index(value = ["mutationId"], unique = true)],
)
data class MosaicEntry(
    @PrimaryKey val id: String,
    val day: Long,
    /** The time zone the entry was first saved in; the day itself never drifts with travel. */
    val zoneId: String,
    val createdAt: Long,
    val updatedAt: Long,
    val habitId: String?,
    /** The habit's name when the entry was saved, so a later rename does not rewrite history. */
    val habitTitle: String?,
    val text: String,
    val mediaId: String?,
    val shape: String,
    /** Where the photo's subject is (0..1 of its width and height) and how far it is zoomed in (≥ 1). */
    val focusX: Float,
    val focusY: Float,
    val zoom: Float,
    /** Set when the entry is in the bin; such entries count for nothing and are purged after a week. */
    val deletedAt: Long? = null,
    /** The draft's id for this save: a second tap or a replayed callback finds the row and stops. */
    val mutationId: String,
    /** How the person felt in this record, 1 (great) to 5 (awful); null when they did not say. Added in version 3. */
    val mood: Int? = null,
)

/** An archived photo: a downscaled JPEG the app wrote itself, never a picker URI. */
@Entity(tableName = "media")
data class MosaicMediaAsset(
    @PrimaryKey val id: String,
    /** Relative to `filesDir/mosaic/media`. */
    val path: String,
    val mime: String,
    val width: Int,
    val height: Int,
    val bytes: Long,
    val sha256: String,
    val createdAt: Long,
)

/** What belongs to a day as a whole: its mood, the entry the person chose as its cover, and its shape. */
@Entity(tableName = "days")
data class MosaicDayInfo(
    @PrimaryKey val day: Long,
    val mood: Int? = null,
    val coverEntryId: String? = null,
    val updatedAt: Long,
    /** The [MosaicForm] the person picked for the day; null follows [MosaicForm.auto]. Added in version 2. */
    val form: String? = null,
)

/**
 * The editor's work in progress for one target (a day, a habit slot or an entry). It is not a
 * record: nothing counts it until [MosaicStore.save] turns it into one.
 */
@Entity(tableName = "drafts", indices = [Index("day")])
data class MosaicDraft(
    @PrimaryKey val id: String,
    val day: Long,
    val habitId: String?,
    val entryId: String?,
    val text: String,
    /** An archived photo the draft keeps (editing an entry that has one). */
    val mediaId: String?,
    /** A newly imported photo, an absolute path under `filesDir/mosaic/drafts`; it wins over [mediaId]. */
    val stagedPath: String?,
    val shape: String,
    val focusX: Float,
    val focusY: Float,
    val zoom: Float,
    val markDone: Boolean,
    /** A mood the person chose in the editor for this record, [MosaicStore.MOOD_CLEARED] for "none"; null leaves it as it was. */
    val mood: Int?,
    val mutationId: String,
    val updatedAt: Long,
)

/** An entry with the path of its photo, the row every view reads. */
data class MosaicEntryRow(
    @Embedded val entry: MosaicEntry,
    val mediaPath: String?,
)

/** 日期选择器只需要已保存记录的数量，不加载文字或图片。 */
data class MosaicRecordCount(val day: Long, val entryCount: Int)

@Dao
interface MosaicDao {
    /** 日历弹窗与列表视图共用记录判定，删除后数量自动更新。 */
    @Query("SELECT day, COUNT(*) AS entryCount FROM entries WHERE deletedAt IS NULL AND day >= :start AND day < :end GROUP BY day ORDER BY day")
    fun observeRecordCounts(start: Long, end: Long): Flow<List<MosaicRecordCount>>

    /** 读取日记原始文字字段，不关联图片表，返回数量受命令入口限制。 */
    @Query("SELECT * FROM entries WHERE deletedAt IS NULL AND day >= :start AND day < :end ORDER BY day, createdAt, id LIMIT :limit")
    suspend fun agentEntriesBetween(start: Long, end: Long, limit: Int): List<MosaicEntry>

    /** 日记当天的心情和更新时间，同一事务中读取。 */
    @Query("SELECT * FROM days WHERE day >= :start AND day < :end")
    suspend fun agentDaysBetween(start: Long, end: Long): List<MosaicDayInfo>

    /** 历史计划按生效日期排序，停用和改名不改变旧计划的含义。 */
    @Query("SELECT * FROM habit_schedules ORDER BY habitId, fromDay")
    suspend fun agentSchedules(): List<MosaicHabitSchedule>

    /** 完成、跳过及未标记的区别由查询输出保留。 */
    @Query("SELECT * FROM habit_days WHERE day >= :start AND day < :end")
    suspend fun agentHabitDaysBetween(start: Long, end: Long): List<MosaicHabitDay>

    @Query(
        "SELECT e.*, m.path AS mediaPath FROM entries e LEFT JOIN media m ON m.id = e.mediaId " +
            "WHERE e.deletedAt IS NULL AND e.day >= :start AND e.day < :end ORDER BY e.day, e.createdAt",
    )
    fun observeEntries(start: Long, end: Long): Flow<List<MosaicEntryRow>>

    @Query("SELECT e.*, m.path AS mediaPath FROM entries e LEFT JOIN media m ON m.id = e.mediaId WHERE e.id = :id")
    suspend fun entryRow(id: String): MosaicEntryRow?

    /** The live records of [start, end), once: the agent's reading of the log ([MosaicAgent]). */
    @Query(
        "SELECT e.*, NULL AS mediaPath FROM entries e " +
            "WHERE e.deletedAt IS NULL AND e.day >= :start AND e.day < :end ORDER BY e.day, e.createdAt, e.id LIMIT :limit OFFSET :offset",
    )
    suspend fun entriesBetween(start: Long, end: Long, limit: Int = 200, offset: Int = 0): List<MosaicEntryRow>

    /** Habit marks of one [state] in [start, end), once. */
    @Query("SELECT * FROM habit_days WHERE state = :state AND day >= :start AND day < :end")
    suspend fun habitDaysBetween(start: Long, end: Long, state: String): List<MosaicHabitDay>

    @Query("SELECT * FROM habits")
    suspend fun allHabits(): List<MosaicHabit>

    @Query("SELECT * FROM entries WHERE id = :id")
    suspend fun entry(id: String): MosaicEntry?

    @Query("SELECT * FROM entries WHERE mutationId = :mutationId")
    suspend fun entryByMutation(mutationId: String): MosaicEntry?

    @Upsert
    suspend fun upsertEntry(entry: MosaicEntry)

    /** Live records for [habitId] on [day] other than [exceptId]. */
    @Query("SELECT COUNT(*) FROM entries WHERE habitId = :habitId AND day = :day AND deletedAt IS NULL AND id != :exceptId")
    suspend fun habitEntriesOn(habitId: String, day: Long, exceptId: String): Int

    @Query("UPDATE entries SET deletedAt = :at, updatedAt = :at WHERE id = :id")
    suspend fun softDelete(id: String, at: Long)

    @Query("UPDATE entries SET deletedAt = NULL, updatedAt = :at WHERE id = :id")
    suspend fun restore(id: String, at: Long)

    @Query("DELETE FROM entries WHERE deletedAt IS NOT NULL AND deletedAt < :before")
    suspend fun purgeDeleted(before: Long): Int

    @Insert(onConflict = OnConflictStrategy.ABORT)
    suspend fun insertMedia(media: MosaicMediaAsset)

    @Query(
        "SELECT * FROM media WHERE createdAt < :before " +
            "AND id NOT IN (SELECT mediaId FROM entries WHERE mediaId IS NOT NULL) " +
            "AND id NOT IN (SELECT mediaId FROM drafts WHERE mediaId IS NOT NULL)",
    )
    suspend fun orphanMedia(before: Long): List<MosaicMediaAsset>

    @Query("DELETE FROM media WHERE id IN (:ids)")
    suspend fun deleteMedia(ids: List<String>)

    @Query("SELECT path FROM media")
    suspend fun mediaPaths(): List<String>

    @Query("SELECT * FROM habits ORDER BY sortOrder, createdAt")
    fun observeHabits(): Flow<List<MosaicHabit>>

    @Query("SELECT * FROM habits WHERE id = :id")
    suspend fun habit(id: String): MosaicHabit?

    @Query("SELECT COALESCE(MAX(sortOrder), -1) FROM habits")
    suspend fun maxHabitOrder(): Int

    @Upsert
    suspend fun upsertHabit(habit: MosaicHabit)

    @Query("SELECT * FROM habit_schedules ORDER BY habitId, fromDay")
    fun observeSchedules(): Flow<List<MosaicHabitSchedule>>

    @Query("SELECT * FROM habit_schedules WHERE habitId = :habitId ORDER BY fromDay")
    suspend fun schedulesOf(habitId: String): List<MosaicHabitSchedule>

    @Upsert
    suspend fun upsertSchedule(schedule: MosaicHabitSchedule)

    @Query("SELECT * FROM habit_days WHERE day >= :start AND day < :end")
    fun observeHabitDays(start: Long, end: Long): Flow<List<MosaicHabitDay>>

    @Query("SELECT * FROM habit_days WHERE habitId = :habitId AND day = :day")
    suspend fun habitDay(habitId: String, day: Long): MosaicHabitDay?

    @Upsert
    suspend fun upsertHabitDay(state: MosaicHabitDay)

    @Query("DELETE FROM habit_days WHERE habitId = :habitId AND day = :day")
    suspend fun clearHabitDay(habitId: String, day: Long)

    @Query("SELECT * FROM days WHERE day >= :start AND day < :end")
    fun observeDays(start: Long, end: Long): Flow<List<MosaicDayInfo>>

    @Query("SELECT * FROM days WHERE day = :day")
    suspend fun dayInfo(day: Long): MosaicDayInfo?

    @Upsert
    suspend fun upsertDay(info: MosaicDayInfo)

    @Query("SELECT * FROM drafts WHERE id = :id")
    suspend fun draft(id: String): MosaicDraft?

    @Query("SELECT * FROM drafts WHERE day = :day ORDER BY updatedAt DESC")
    fun observeDrafts(day: Long): Flow<List<MosaicDraft>>

    @Upsert
    suspend fun upsertDraft(draft: MosaicDraft)

    @Query("DELETE FROM drafts WHERE id = :id")
    suspend fun deleteDraft(id: String)

    @Query("SELECT stagedPath FROM drafts WHERE stagedPath IS NOT NULL")
    suspend fun stagedPaths(): List<String>
}

/**
 * 版本6增加按账号隔离的专注记录与日记关联，保留日记与任务历史。
 * 结构由KSP导出至app/schemas，每次升级使用显式迁移，禁止破坏性回退。
 */
@Database(
    entities = [
        io.github.nanomuse.focus.FocusSession::class,
        io.github.nanomuse.focus.FocusSpan::class,
        io.github.nanomuse.focus.FocusOperation::class,
        io.github.nanomuse.focus.FocusEntryLink::class,
        io.github.nanomuse.focus.FocusDraftLink::class,
        MosaicHabit::class,
        MosaicHabitSchedule::class,
        MosaicHabitDay::class,
        MosaicEntry::class,
        MosaicMediaAsset::class,
        MosaicDayInfo::class,
        MosaicDraft::class,
        io.github.nanomuse.todo.TodoTask::class,
        io.github.nanomuse.todo.TodoCategory::class,
        io.github.nanomuse.todo.TodoEntryLink::class,
        io.github.nanomuse.todo.TodoDraftLink::class,
        io.github.nanomuse.todo.TodoOperation::class,
        io.github.nanomuse.todo.TodoEvent::class,
    ],
    version = 6,
    exportSchema = true,
)
abstract class MosaicDatabase : RoomDatabase() {
    abstract fun dao(): MosaicDao

    /** 待办与碎片共享事务，查询始终显式限定账号。 */
    abstract fun todoDao(): io.github.nanomuse.todo.TodoDao

    abstract fun focusDao(): io.github.nanomuse.focus.FocusDao

    companion object {
        @Volatile private var instance: MosaicDatabase? = null

        /** Each day's chosen shape; existing days keep null and follow the automatic one. */
        private val MIGRATION_1_2 = object : Migration(1, 2) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL("ALTER TABLE days ADD COLUMN form TEXT")
            }
        }

        /** Each record's own mood; records written before keep the mood their day had. */
        private val MIGRATION_2_3 = object : Migration(2, 3) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL("ALTER TABLE entries ADD COLUMN mood INTEGER")
                db.execSQL("UPDATE entries SET mood = (SELECT d.mood FROM days d WHERE d.day = entries.day)")
            }
        }

        fun get(context: Context): MosaicDatabase = instance ?: synchronized(this) {
            instance ?: Room.databaseBuilder(context.applicationContext, MosaicDatabase::class.java, "mosaic.db")
                .addMigrations(MIGRATION_1_2, MIGRATION_2_3, io.github.nanomuse.todo.TodoMigration.MIGRATION_3_4, io.github.nanomuse.todo.TodoMigration.MIGRATION_4_5, io.github.nanomuse.focus.FocusMigration.MIGRATION_5_6)
                .build()
                .also { instance = it }
        }
    }
}
