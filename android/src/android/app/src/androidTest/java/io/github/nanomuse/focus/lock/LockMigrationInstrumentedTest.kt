package io.github.nanomuse.focus.lock

import androidx.room.testing.MigrationTestHelper
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import io.github.nanomuse.mosaic.MosaicDatabase
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/** 使用Room导出的v6数据库验证升级，并保留原有专注及日记数据。 */
@RunWith(AndroidJUnit4::class)
class LockMigrationInstrumentedTest {
    @get:Rule
    val helper = MigrationTestHelper(
        InstrumentationRegistry.getInstrumentation(),
        MosaicDatabase::class.java,
        emptyList()
    )

    /** 迁移测试仅允许在隔离测试包内创建数据库。 */
    @Before
    fun requireIsolatedPackage() {
        check(InstrumentationRegistry.getInstrumentation().targetContext.packageName.endsWith(".uitest"))
    }

    /** 升级只新增锁机表，不改变专注记录、区间、目录和日记。 */
    @Test
    fun should_preserveFocusAndDiary_when_migratingSixToSeven() {
        helper.createDatabase("lock-migration-test", 6).apply {
            execSQL("""INSERT INTO focus_sessions VALUES ('owner', 'focus', '原专注', NULL,
                '学习', '[]', 'timer', 60000, 'paused', 23000, 1000, NULL, 24000,
                1000, 2000, 3, 2, NULL)""")
            execSQL("INSERT INTO focus_spans VALUES ('owner', 'span', 'focus', 1000, 23000)")
            execSQL("INSERT INTO todo_categories VALUES ('owner', 'group', '保留目录', 1, 2)")
            execSQL("""INSERT INTO entries VALUES ('entry', 20000, 'Asia/Shanghai', 1, 2,
                NULL, NULL, '保留日记', NULL, 'rounded', 0.5, 0.5, 1, NULL, 'mutation', 2)""")
            close()
        }
        helper.runMigrationsAndValidate(
            "lock-migration-test", 7, true, LockMigration.MIGRATION_6_7
        ).use { database ->
            database.query("SELECT title, status, elapsedMs, revision FROM focus_sessions").use { row ->
                assertTrue(row.moveToFirst())
                assertEquals("原专注", row.getString(0))
                assertEquals("paused", row.getString(1))
                assertEquals(23000L, row.getLong(2))
                assertEquals(2L, row.getLong(3))
            }
            database.query("SELECT durationMs FROM focus_spans").use { row ->
                assertTrue(row.moveToFirst())
                assertEquals(23000L, row.getLong(0))
            }
            database.query("SELECT name FROM todo_categories").use { row ->
                assertTrue(row.moveToFirst())
                assertEquals("保留目录", row.getString(0))
            }
            database.query("SELECT text FROM entries").use { row ->
                assertTrue(row.moveToFirst())
                assertEquals("保留日记", row.getString(0))
            }
            listOf("focus_lock_plans", "focus_lock_whitelist", "focus_lock_runs").forEach { table ->
                database.query("SELECT COUNT(*) FROM $table").use { row ->
                    assertTrue(row.moveToFirst())
                    assertEquals(0, row.getInt(0))
                }
            }
        }
    }
}
