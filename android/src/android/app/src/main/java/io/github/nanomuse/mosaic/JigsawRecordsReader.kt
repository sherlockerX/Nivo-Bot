package io.github.nanomuse.mosaic

import android.content.Context
import androidx.room.withTransaction
import io.github.nanomuse.account.AccountData
import io.github.nanomuse.account.AccountOperation
import io.github.nanomuse.focus.FocusEntryLink
import io.github.nanomuse.todo.TodoEntryLink
import java.time.LocalDate
import org.json.JSONObject

/** nanoMuse: 设备本地日记与当前账号关联快照共用一次只读事务，并固定发起账号代次。 */
class JigsawRecordsReader internal constructor(
    context: Context,
    private val database: MosaicDatabase,
    private val operation: AccountOperation = AccountData.captureOperation(),
) {
    private val ownerKey: String
    private val ownerEpoch: Long

    init {
        operation.requireCurrent()
        ownerKey = AccountData.key(context.applicationContext)
        ownerEpoch = AccountData.epoch.value
        operation.requireCurrent()
    }

    /** 固定本次查询的账号及操作凭证，数据库正文仍属于设备本地。 */
    constructor(context: Context) : this(context, MosaicDatabase.get(context))

    /** 读取半开日期区间，超过5000条显式拒绝，关联按最多400个记录ID分批。 */
    suspend fun read(startDay: Long, endDay: Long): JigsawSnapshot = guardedRead {
        require(startDay < endDay) { "The start day must be before the exclusive end day." }
        val dao = database.dao()
        val entries = dao.agentEntriesBetween(startDay, endDay, MAX_ENTRIES + 1)
        require(entries.size <= MAX_ENTRIES) {
            "Too many records. Use a smaller range or --limit; no text was truncated."
        }
        val todoLinks = mutableListOf<TodoEntryLink>()
        val focusLinks = mutableListOf<FocusEntryLink>()
        for (entryIds in entries.map { it.id }.chunked(LINK_BATCH_SIZE)) {
            todoLinks += database.todoDao().entryLinksForEntries(ownerKey, entryIds)
            focusLinks += database.focusDao().entryLinksForEntries(ownerKey, entryIds)
        }
        JigsawSnapshot(entries, dao.agentDaysBetween(startDay, endDay), dao.allHabits(),
            dao.agentSchedules(), dao.agentHabitDaysBetween(startDay, endDay), todoLinks, focusLinks)
    }

    /** 只聚合有效日记的保存日期与数量，空库显式返回空日期，不读取正文。 */
    suspend fun range(): JSONObject = guardedRead {
        val bounds = database.dao().agentRecordRange()
        JSONObject().put("scope", "device_local").put("linked_records_scope", "current_account")
            .put("range_basis", "non_deleted_entries").put("timezone", java.time.ZoneId.systemDefault().id)
            .put("earliest_date", bounds.earliestDay?.let { LocalDate.ofEpochDay(it).toString() } ?: JSONObject.NULL)
            .put("latest_date", bounds.latestDay?.let { LocalDate.ofEpochDay(it).toString() } ?: JSONObject.NULL)
            .put("entry_count", bounds.entryCount)
    }

    private suspend fun <T> guardedRead(block: suspend () -> T): T {
        operation.requireCurrent()
        val result = AccountData.withTodoOwnerMutation(ownerKey, ownerEpoch) {
            operation.requireCurrent()
            database.withTransaction {
                val snapshot = block()
                operation.requireCurrent()
                snapshot
            }
        }
        operation.requireCurrent()
        return result
    }

    private companion object {
        const val MAX_ENTRIES = 5_000
        const val LINK_BATCH_SIZE = 400
    }
}
