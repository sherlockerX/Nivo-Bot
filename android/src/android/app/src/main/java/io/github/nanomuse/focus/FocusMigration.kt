package io.github.nanomuse.focus

import androidx.room.migration.Migration
import androidx.sqlite.db.SupportSQLiteDatabase

/** v6仅增加专注表，不修改待办与日记原始字段。 */
object FocusMigration {
    val MIGRATION_5_6 = object : Migration(5, 6) {
        override fun migrate(db: SupportSQLiteDatabase) {
            db.execSQL("""CREATE TABLE IF NOT EXISTS focus_sessions (ownerKey TEXT NOT NULL, id TEXT NOT NULL,
                title TEXT NOT NULL, taskId TEXT, groupName TEXT NOT NULL, tagsJson TEXT NOT NULL, mode TEXT NOT NULL,
                targetMs INTEGER NOT NULL, status TEXT NOT NULL, elapsedMs INTEGER NOT NULL, startedAt INTEGER NOT NULL,
                endedAt INTEGER, updatedAt INTEGER NOT NULL, runningWall INTEGER NOT NULL, runningElapsed INTEGER NOT NULL,
                bootCount INTEGER NOT NULL, revision INTEGER NOT NULL, deletedAt INTEGER, PRIMARY KEY(ownerKey,id))""")
            db.execSQL("CREATE TABLE IF NOT EXISTS focus_spans (ownerKey TEXT NOT NULL,id TEXT NOT NULL,sessionId TEXT NOT NULL,startedAt INTEGER NOT NULL,durationMs INTEGER NOT NULL,PRIMARY KEY(ownerKey,id))")
            db.execSQL("CREATE TABLE IF NOT EXISTS focus_operations (ownerKey TEXT NOT NULL,id TEXT NOT NULL,request TEXT NOT NULL,result TEXT NOT NULL,PRIMARY KEY(ownerKey,id))")
            db.execSQL("CREATE TABLE IF NOT EXISTS focus_entry_links (ownerKey TEXT NOT NULL,entryId TEXT NOT NULL,sessionId TEXT NOT NULL,title TEXT NOT NULL,startedAt INTEGER NOT NULL,endedAt INTEGER NOT NULL,durationMs INTEGER NOT NULL,PRIMARY KEY(ownerKey,entryId,sessionId))")
            db.execSQL("CREATE TABLE IF NOT EXISTS focus_draft_links (ownerKey TEXT NOT NULL,draftId TEXT NOT NULL,sessionId TEXT NOT NULL,PRIMARY KEY(ownerKey,draftId,sessionId))")
        }
    }
}
