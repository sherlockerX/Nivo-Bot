package io.github.nanomuse.chat

import androidx.room.migration.Migration
import androidx.sqlite.db.SupportSQLiteDatabase
import io.github.nanomuse.routines.ScheduledRunJournal
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/** 只整理名称，不合并分组或推测历史任务归属，成员ID保持不变。 */
object GroupSchemaMigration : Migration(12, 13) {
    override fun migrate(db: SupportSQLiteDatabase) {
        val groups = rows(db, "folders")
        val backup = JSONObject().put("folders", groups).put("sessions", rows(db, "sessions"))
        val parent = File(db.path).parentFile?.parentFile ?: error("DATABASE_BACKUP_PATH_INVALID")
        val journal = ScheduledRunJournal(File(parent, "files/minis-global/home"))
        journal.backupGroups(backup.toString())
        db.execSQL("ALTER TABLE folders ADD COLUMN name_key TEXT NOT NULL DEFAULT ''")
        db.execSQL("ALTER TABLE sessions ADD COLUMN group_assigned_by TEXT")
        db.execSQL("ALTER TABLE sessions ADD COLUMN created_by_task_id TEXT")
        db.execSQL("ALTER TABLE sessions ADD COLUMN created_by_run_id TEXT")
        val entries = (0 until groups.length()).map { groups.getJSONObject(it) }
            .sortedWith(compareBy<JSONObject> { it.getLong("created_at") }.thenBy { it.getString("id") })
        val reserved = entries.map { GroupNamePolicy.key(GroupNamePolicy.legacyBase(it.getString("name"))) }.toSet()
        val assigned = mutableSetOf<String>()
        val renamed = JSONArray()
        entries.forEach { entry ->
            val id = entry.getString("id")
            val oldName = entry.getString("name")
            val base = GroupNamePolicy.legacyBase(oldName)
            var name = base
            var number = 2
            while (GroupNamePolicy.key(name) in assigned ||
                (id != GroupNamePolicy.SYSTEM_ID && runCatching { GroupNamePolicy.validate(name) }.isFailure)) {
                name = GroupNamePolicy.numbered(base, number++)
                while (GroupNamePolicy.key(name) in reserved || GroupNamePolicy.key(name) in assigned) name = GroupNamePolicy.numbered(base, number++)
            }
            val key = GroupNamePolicy.key(name)
            assigned.add(key)
            db.execSQL("UPDATE folders SET name = ?, name_key = ? WHERE id = ?", arrayOf(name, key, id))
            if (name != oldName) renamed.put(JSONObject().put("id", id).put("old_name", oldName).put("name", name))
        }
        db.execSQL("CREATE UNIQUE INDEX index_folders_name_key ON folders(name_key)")
        journal.groupMigrationReport(JSONObject().put("renamed", renamed)
            .put("historical_sessions_moved", 0).put("reason", "Unknown and test history is preserved for manual review"))
    }

    private fun rows(db: SupportSQLiteDatabase, table: String): JSONArray {
        val output = JSONArray()
        db.query("SELECT * FROM $table").use { cursor ->
            while (cursor.moveToNext()) {
                val row = JSONObject()
                cursor.columnNames.forEachIndexed { index, column ->
                    row.put(column, if (cursor.isNull(index)) JSONObject.NULL else when (cursor.getType(index)) {
                        1 -> cursor.getLong(index); 2 -> cursor.getDouble(index); else -> cursor.getString(index)
                    })
                }
                output.put(row)
            }
        }
        return output
    }
}
