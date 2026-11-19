package io.github.nanomuse.focus.lock

import androidx.room.migration.Migration
import androidx.sqlite.db.SupportSQLiteDatabase

/** v7仅新增按账号隔离的锁机表，保留专注、待办及日记原有结构。 */
object LockMigration {
    /** 从v6升级，不重建或更新任何旧表。 */
    val MIGRATION_6_7 = object : Migration(6, 7) {
        /** 建立计划、全局白名单和运行记录，并为活动及会话查询建立索引。 */
        override fun migrate(db: SupportSQLiteDatabase) {
            db.execSQL("""CREATE TABLE IF NOT EXISTS focus_lock_plans (
                ownerKey TEXT NOT NULL, id TEXT NOT NULL, name TEXT NOT NULL,
                enabled INTEGER NOT NULL, daysMask INTEGER NOT NULL, rangesJson TEXT NOT NULL,
                useWhitelist INTEGER NOT NULL, title TEXT, taskId TEXT, revision INTEGER NOT NULL,
                updatedAt INTEGER NOT NULL, deletedAt INTEGER, PRIMARY KEY(ownerKey, id))""")
            db.execSQL("""CREATE TABLE IF NOT EXISTS focus_lock_whitelist (
                ownerKey TEXT NOT NULL, packageName TEXT NOT NULL, addedAt INTEGER NOT NULL,
                PRIMARY KEY(ownerKey, packageName))""")
            db.execSQL("""CREATE TABLE IF NOT EXISTS focus_lock_runs (
                ownerKey TEXT NOT NULL, id TEXT NOT NULL, sessionId TEXT NOT NULL,
                planIds TEXT NOT NULL, occurrenceIds TEXT NOT NULL, startedAt INTEGER NOT NULL,
                deadlineAt INTEGER NOT NULL, durationMs INTEGER NOT NULL, useWhitelist INTEGER NOT NULL,
                checkpointRemainingMs INTEGER NOT NULL, checkpointElapsed INTEGER NOT NULL,
                bootCount INTEGER NOT NULL, status TEXT NOT NULL, endedAt INTEGER,
                PRIMARY KEY(ownerKey, id))""")
            db.execSQL("CREATE UNIQUE INDEX IF NOT EXISTS index_focus_lock_runs_ownerKey_sessionId ON focus_lock_runs (ownerKey, sessionId)")
            db.execSQL("CREATE INDEX IF NOT EXISTS index_focus_lock_runs_ownerKey_status ON focus_lock_runs (ownerKey, status)")
        }
    }
}
