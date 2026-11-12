package io.github.nanomuse.todo

import androidx.room.migration.Migration
import androidx.sqlite.db.SupportSQLiteDatabase

/** 只新增待办表，完整保留原有Mosaic记录和草稿。 */
object TodoMigration {
    val MIGRATION_3_4: Migration = object : Migration(3, 4) {
        override fun migrate(db: SupportSQLiteDatabase) {
            createTasks(db)
            createLinks(db)
            createHistory(db)
        }
    }

    /** 只增加分类目录，从已有任务回填；任务修订号、完成标签与日记均不改变。 */
    val MIGRATION_4_5: Migration = object : Migration(4, 5) {
        override fun migrate(db: SupportSQLiteDatabase) {
            db.execSQL("""CREATE TABLE IF NOT EXISTS todo_categories (
                ownerKey TEXT NOT NULL, kind TEXT NOT NULL, name TEXT NOT NULL,
                createdAt INTEGER NOT NULL, updatedAt INTEGER NOT NULL,
                PRIMARY KEY(ownerKey, kind, name))""")
            db.query("SELECT ownerKey, groupName, tagsJson, createdAt, updatedAt FROM todo_tasks ORDER BY createdAt").use { rows ->
                while (rows.moveToNext()) {
                    val owner = rows.getString(0)
                    val created = rows.getLong(3)
                    val updated = rows.getLong(4)
                    val group = rows.getString(1).trim()
                    if (group.isNotEmpty()) insertCategory(db, owner, "group", group, created, updated)
                    parseTodoTags(rows.getString(2)).forEach { insertCategory(db, owner, "tag", it, created, updated) }
                }
            }
        }
    }

    private fun insertCategory(db: SupportSQLiteDatabase, owner: String, kind: String, name: String, created: Long, updated: Long) {
        db.execSQL("INSERT OR IGNORE INTO todo_categories VALUES (?, ?, ?, ?, ?)", arrayOf<Any>(owner, kind, name, created, updated))
    }

    private fun createTasks(db: SupportSQLiteDatabase) {
        db.execSQL("""CREATE TABLE IF NOT EXISTS todo_tasks (
            ownerKey TEXT NOT NULL, id TEXT NOT NULL, title TEXT NOT NULL, notes TEXT NOT NULL,
            status TEXT NOT NULL, scheduledDay INTEGER, dueDay INTEGER, groupName TEXT NOT NULL,
            tagsJson TEXT NOT NULL, isImportant INTEGER NOT NULL, isUrgent INTEGER NOT NULL,
            revision INTEGER NOT NULL, createdAt INTEGER NOT NULL, updatedAt INTEGER NOT NULL,
            deletedAt INTEGER, completedDay INTEGER, completedAt INTEGER, completionTagsJson TEXT NOT NULL,
            PRIMARY KEY(ownerKey, id))""")
        db.execSQL("CREATE INDEX IF NOT EXISTS index_todo_tasks_ownerKey_status_deletedAt ON todo_tasks(ownerKey, status, deletedAt)")
        db.execSQL("CREATE INDEX IF NOT EXISTS index_todo_tasks_ownerKey_scheduledDay ON todo_tasks(ownerKey, scheduledDay)")
        db.execSQL("CREATE INDEX IF NOT EXISTS index_todo_tasks_ownerKey_completedDay ON todo_tasks(ownerKey, completedDay)")
    }

    private fun createLinks(db: SupportSQLiteDatabase) {
        db.execSQL("""CREATE TABLE IF NOT EXISTS todo_entry_links (
            ownerKey TEXT NOT NULL, entryId TEXT NOT NULL, taskId TEXT NOT NULL, title TEXT NOT NULL,
            statusSnapshot TEXT NOT NULL, linkedAt INTEGER NOT NULL, PRIMARY KEY(ownerKey, entryId, taskId))""")
        db.execSQL("CREATE INDEX IF NOT EXISTS index_todo_entry_links_ownerKey_taskId ON todo_entry_links(ownerKey, taskId)")
        db.execSQL("""CREATE TABLE IF NOT EXISTS todo_draft_links (
            ownerKey TEXT NOT NULL, draftId TEXT NOT NULL, taskId TEXT NOT NULL,
            expectedRevision INTEGER NOT NULL, requestedStatus TEXT, completedDay INTEGER,
            PRIMARY KEY(ownerKey, draftId, taskId))""")
    }

    private fun createHistory(db: SupportSQLiteDatabase) {
        db.execSQL("""CREATE TABLE IF NOT EXISTS todo_operations (
            ownerKey TEXT NOT NULL, operationId TEXT NOT NULL, requestJson TEXT NOT NULL,
            resultJson TEXT NOT NULL, createdAt INTEGER NOT NULL, PRIMARY KEY(ownerKey, operationId))""")
        db.execSQL("""CREATE TABLE IF NOT EXISTS todo_events (
            ownerKey TEXT NOT NULL, operationId TEXT NOT NULL, taskId TEXT NOT NULL,
            previousStatus TEXT, status TEXT NOT NULL, completedDay INTEGER,
            tagsJson TEXT NOT NULL, createdAt INTEGER NOT NULL, PRIMARY KEY(ownerKey, operationId))""")
        db.execSQL("CREATE INDEX IF NOT EXISTS index_todo_events_ownerKey_taskId ON todo_events(ownerKey, taskId)")
    }
}
