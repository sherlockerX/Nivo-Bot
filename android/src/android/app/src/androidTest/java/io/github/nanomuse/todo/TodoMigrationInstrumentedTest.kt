package io.github.nanomuse.todo

import androidx.room.testing.MigrationTestHelper
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import io.github.nanomuse.mosaic.MosaicDatabase
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/** 从导出的真实版本3结构升级，防止新增待办时丢失已有日记。 */
@RunWith(AndroidJUnit4::class)
class TodoMigrationInstrumentedTest {
    @get:Rule val helper = MigrationTestHelper(InstrumentationRegistry.getInstrumentation(), MosaicDatabase::class.java, emptyList())

    @Before fun requireIsolatedPackage() {
        check(InstrumentationRegistry.getInstrumentation().targetContext.packageName.endsWith(".uitest"))
    }

    @Test fun should_preserveDiaryAndDraft_when_migratingThreeToFour() {
        helper.createDatabase("todo-migration-test", 3).apply {
            execSQL("INSERT INTO entries (id, day, zoneId, createdAt, updatedAt, habitId, habitTitle, text, mediaId, shape, focusX, focusY, zoom, deletedAt, mutationId, mood) VALUES ('entry', 20000, 'Asia/Shanghai', 1, 2, NULL, NULL, '保留的文字', NULL, 'rounded', 0.5, 0.5, 1, NULL, 'mutation', 2)")
            execSQL("INSERT INTO drafts (id, day, habitId, entryId, text, mediaId, stagedPath, shape, focusX, focusY, zoom, markDone, mood, mutationId, updatedAt) VALUES ('draft', 20001, NULL, NULL, '未完成的草稿', NULL, NULL, 'rounded', 0.5, 0.5, 1, 0, NULL, 'draft-mutation', 3)")
            close()
        }
        helper.runMigrationsAndValidate("todo-migration-test", 4, true, TodoMigration.MIGRATION_3_4).use { db ->
            db.query("SELECT text, mood FROM entries WHERE id = 'entry'").use { row ->
                assertTrue(row.moveToFirst()); assertEquals("保留的文字", row.getString(0)); assertEquals(2, row.getInt(1))
            }
            db.query("SELECT text FROM drafts WHERE id = 'draft'").use { row ->
                assertTrue(row.moveToFirst()); assertEquals("未完成的草稿", row.getString(0))
            }
            db.query("SELECT COUNT(*) FROM todo_tasks").use { row -> assertTrue(row.moveToFirst()); assertEquals(0, row.getInt(0)) }
        }
    }
    @Test fun should_backfillCategoriesWithoutChangingTask_when_migratingFourToFive() {
        helper.createDatabase("todo-category-migration-test", 4).apply {
            execSQL("""INSERT INTO todo_tasks VALUES ('owner', 'task', '保留标题', '', 'done', NULL, NULL, '个人成长', '["阅读","复盘"]', 0, 0, 7, 1, 2, NULL, 20000, 2, '["原标签"]')""")
            close()
        }
        helper.runMigrationsAndValidate("todo-category-migration-test", 5, true, TodoMigration.MIGRATION_4_5).use { db ->
            db.query("SELECT name FROM todo_categories WHERE ownerKey = 'owner'").use { rows ->
                val names = mutableSetOf<String>()
                while (rows.moveToNext()) names += rows.getString(0)
                assertEquals(setOf("个人成长", "阅读", "复盘"), names)
            }
            db.query("SELECT revision, completionTagsJson FROM todo_tasks WHERE id = 'task'").use { rows ->
                assertTrue(rows.moveToFirst()); assertEquals(7, rows.getInt(0)); assertEquals("[\"原标签\"]", rows.getString(1))
            }
        }
    }

}
