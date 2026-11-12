package io.github.nanomuse.focus

import androidx.room.testing.MigrationTestHelper
import androidx.test.platform.app.InstrumentationRegistry
import io.github.nanomuse.mosaic.MosaicDatabase
import org.junit.*
import org.junit.Assert.*

/** 从真实v5结构升级，原目录和日记不能丢失。 */
class FocusMigrationInstrumentedTest {
    @get:Rule val helper=MigrationTestHelper(InstrumentationRegistry.getInstrumentation(),MosaicDatabase::class.java,emptyList())
    @Test fun should_keepCategoryAndDiary_whenMigratingFiveToSix() {
        check(InstrumentationRegistry.getInstrumentation().targetContext.packageName.endsWith(".uitest"))
        helper.createDatabase("focus-migration",5).apply {
            execSQL("INSERT INTO todo_categories VALUES ('owner','group','保留',1,1)")
            close()
        }
        helper.runMigrationsAndValidate("focus-migration",6,true,FocusMigration.MIGRATION_5_6).use { db ->
            db.query("SELECT name FROM todo_categories").use { assertTrue(it.moveToFirst());assertEquals("保留",it.getString(0)) }
            db.query("SELECT COUNT(*) FROM focus_sessions").use { assertTrue(it.moveToFirst());assertEquals(0,it.getInt(0)) }
        }
    }
}
