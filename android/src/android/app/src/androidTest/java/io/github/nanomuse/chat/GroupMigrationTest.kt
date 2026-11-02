package io.github.nanomuse.chat

import androidx.room.testing.MigrationTestHelper
import androidx.sqlite.db.framework.FrameworkSQLiteOpenHelperFactory
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.openminis.app.data.db.AppDatabase
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import java.util.UUID

/** 在Android真实ICU和SQLite中验证升级，不访问主应用数据库。 */
@RunWith(AndroidJUnit4::class)
class GroupMigrationTest {
    /** 防止测试误操作正式安装包的数据。 */
    @Before fun requireIsolatedPackage() {
        check(InstrumentationRegistry.getInstrumentation().targetContext.packageName.endsWith(".uitest"))
    }
    @get:Rule val helper = MigrationTestHelper(InstrumentationRegistry.getInstrumentation(),
        AppDatabase::class.java.canonicalName!!, FrameworkSQLiteOpenHelperFactory())

    @Test fun should_preserveMembersAndUnknownHistory_when_migratingDuplicateNames() {
        val name = "group-migration-${UUID.randomUUID()}.db"
        helper.createDatabase(name, 12).use { database ->
            listOf("X", "X", "X", "X (2)").forEachIndexed { index, title ->
                database.execSQL("INSERT INTO folders(id,name,origin,sort_index,created_at,updated_at) VALUES(?,?,'manual',0,?,?)", arrayOf("group$index", title, index + 1, index + 1))
                database.execSQL("INSERT INTO sessions(id,model_id,created_at,updated_at,memory_enabled,edit_count,folder_id) VALUES(?,'fixture',1,1,1,0,?)", arrayOf("session$index", "group$index"))
            }
            database.execSQL("INSERT INTO sessions(id,model_id,created_at,updated_at,memory_enabled,edit_count,source) VALUES('unknown','fixture',1,1,1,0,'scheduled')")
        }
        helper.runMigrationsAndValidate(name, 13, true, GroupSchemaMigration).use { database ->
            database.query("SELECT name FROM folders ORDER BY created_at").use { cursor ->
                val names = mutableListOf<String>()
                while (cursor.moveToNext()) names.add(cursor.getString(0))
                assertEquals(listOf("X", "X (3)", "X (4)", "X (2)"), names)
            }
            database.query("SELECT id,folder_id FROM sessions WHERE id != 'unknown' ORDER BY id").use { cursor ->
                var index = 0
                while (cursor.moveToNext()) { assertEquals("group$index", cursor.getString(1)); index++ }
                assertEquals(4, index)
            }
            database.query("SELECT folder_id,group_assigned_by FROM sessions WHERE id='unknown'").use { cursor ->
                assertTrue(cursor.moveToFirst()); assertTrue(cursor.isNull(0)); assertTrue(cursor.isNull(1))
            }
            assertThrows(android.database.sqlite.SQLiteConstraintException::class.java) {
                database.execSQL("INSERT INTO folders(id,name,name_key,origin,sort_index,created_at,updated_at) VALUES('other','x','x','manual',0,9,9)")
            }
        }
        InstrumentationRegistry.getInstrumentation().targetContext.deleteDatabase(name)
    }

    @Test fun should_foldFullUnicodeOnDevice_withoutConflatingDotlessI() {
        assertEquals(GroupNamePolicy.key("Straße"), GroupNamePolicy.key("STRASSE"))
        assertEquals(GroupNamePolicy.key("ς"), GroupNamePolicy.key("Σ"))
        assertNotEquals(GroupNamePolicy.key("ı"), GroupNamePolicy.key("i"))
    }
}
