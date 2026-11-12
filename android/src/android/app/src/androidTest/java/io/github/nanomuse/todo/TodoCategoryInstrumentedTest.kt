package io.github.nanomuse.todo

import android.content.Context
import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import io.github.nanomuse.account.AccountData
import io.github.nanomuse.mosaic.MosaicDatabase
import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/** 独立Room数据库验证目录、旧备份、隔离与事务，不写用户学习档案。 */
@RunWith(AndroidJUnit4::class)
class TodoCategoryInstrumentedTest {
    private lateinit var context: Context
    private lateinit var database: MosaicDatabase
    private lateinit var store: TodoStore

    @Before fun prepare() {
        context = ApplicationProvider.getApplicationContext()
        check(context.packageName.endsWith(".uitest"))
        database = Room.inMemoryDatabaseBuilder(context, MosaicDatabase::class.java).build()
        store = TodoStore(context, database, AccountData.key(context), AccountData.epoch.value)
    }
    @After fun close() { database.close() }

    @Test fun should_manageCategoriesThroughTool_andKeepDeletedGenerationSafe()=runBlocking {
        val bridge=TodoAgentBridge(TodoStoreToolStorage(store))
        val user=TodoToolUser("user","创建分组，然后删除测试分组","main")
        val create="""{"action":"create_category","operationId":"category-create","categoryKind":"group","categoryName":"测试分组"}"""
        val created=bridge.command(create,user)
        assertTrue(created.output,created.success)
        val category=store.categories().single()
        val task=store.saveTask(TodoTask(ownerKey=store.ownerKey,title="保留任务",groupName=category.name),"task")
        val deletion=JSONObject().put("action","delete_category").put("operationId","category-delete")
            .put("categoryKind","group").put("categoryName",category.name).put("expectedCreatedAt",category.createdAt).toString()
        assertTrue(bridge.command(deletion,user).success)
        assertEquals("",store.task(task.id)?.groupName)
        assertTrue(store.categories().isEmpty())
        store.createCategory("group",category.name)
        assertTrue(bridge.command(deletion,user).success)
        assertEquals(1,store.categories().size)
        assertFalse(bridge.command(deletion.replace("category-delete","new-operation"),user).success)
        val backup=store.exportJson()
        assertEquals(2,JSONObject(backup).getJSONArray("categoryOperations").length())
        database.todoDao().deleteOwnerTasks(store.ownerKey)
        database.todoDao().deleteOwnerCategories(store.ownerKey)
        database.todoDao().deleteOwnerOperations(store.ownerKey)
        database.todoDao().deleteOwnerEvents(store.ownerKey)
        store.importJson(backup)
        assertTrue(bridge.command(deletion,user).success)
        assertEquals(1,store.categories().size)
    }

    @Test fun should_keepUnusedCategories_when_recreatingStoreAndDeletingTask() = runBlocking {
        store.createCategory("group", "  个人成长  ")
        store.createCategory("tag", "阅读")
        store.createCategory("tag", " 阅读 ")
        val recreated = TodoStore(context, database, store.ownerKey, store.ownerEpoch)
        assertEquals(setOf("个人成长", "阅读"), recreated.categories().map { it.name }.toSet())
        val task = recreated.saveTask(TodoTask(ownerKey = store.ownerKey, title = "测试", groupName = "课外实践", tagsJson = "[\"协作\"]"), "create")
        recreated.deleteTask(task.id, task.revision, "delete")
        assertEquals(4, recreated.categories().size)
    }

    @Test fun should_rejectStaleOwnerAndHideOtherDirectory_when_querying() = runBlocking {
        store.createCategory("tag", "自己")
        database.todoDao().putCategories(listOf(TodoCategory("other", "tag", "其他账号", 1, 1)))
        val result = TodoAgentBridge(TodoStoreToolStorage(store)).query("{\"kind\":\"categories\"}")
        assertTrue(result.success); assertTrue(result.output.contains("自己")); assertFalse(result.output.contains("其他账号"))
        val stale = TodoStore(context, database, store.ownerKey, store.ownerEpoch - 1)
        assertTrue(runCatching { stale.createCategory("group", "不应保存") }.isFailure)
        assertEquals(1, store.categories().size)
    }

    @Test fun should_roundTripUnusedDirectory_andReadLegacyBackup() = runBlocking {
        store.createCategory("group", "空分组")
        store.createCategory("tag", "未使用标签")
        val backup = store.exportJson()
        assertEquals(2, JSONObject(backup).getInt("version"))
        database.todoDao().deleteOwnerCategories(store.ownerKey)
        assertEquals(0, store.importJson(backup))
        assertEquals(setOf("空分组", "未使用标签"), store.categories().map { it.name }.toSet())
        store.saveTask(TodoTask(ownerKey = store.ownerKey, title = "旧备份", groupName = "旧组", tagsJson = "[\"旧标签\"]"), "legacy-create")
        val legacy = JSONObject(store.exportJson()).put("version", 1).apply { remove("categories") }.toString()
        database.todoDao().deleteOwnerTasks(store.ownerKey)
        database.todoDao().deleteOwnerCategories(store.ownerKey)
        database.todoDao().deleteOwnerOperations(store.ownerKey)
        database.todoDao().deleteOwnerEvents(store.ownerKey)
        assertEquals(1, store.importJson(legacy))
        assertEquals(setOf("旧组", "旧标签"), store.categories().map { it.name }.toSet())
    }

    @Test fun should_rollbackDirectory_when_importContainsInvalidCategory() = runBlocking {
        store.createCategory("group", "保留")
        val backup = JSONObject(store.exportJson())
        backup.getJSONArray("categories").put(JSONObject().put("kind", "tag").put("name", "") .put("createdAt", 1).put("updatedAt", 1))
        assertTrue(runCatching { store.importJson(backup.toString()) }.isFailure)
        assertEquals(listOf("保留"), store.categories().map { it.name })
    }
    @Test fun should_deleteGroupAndTag_withoutDeletingTaskOrHistory() = runBlocking {
        val original = store.saveTask(TodoTask(ownerKey=store.ownerKey,title="保留任务",groupName="旧分组",tagsJson="[\"旧标签\",\"保留标签\"]"),"category-task")
        val done = store.changeStatus(original.id,"done",original.revision,"category-done")
        val snapshot = done.completionTagsJson
        val group = store.categories().single { it.kind=="group" }
        val tag = store.categories().single { it.name=="旧标签" }
        store.deleteCategory(group.kind,group.name,group.createdAt)
        store.deleteCategory(tag.kind,tag.name,tag.createdAt)
        val after = checkNotNull(store.task(original.id))
        assertEquals("",after.groupName);assertEquals(listOf("保留标签"),after.tags())
        assertEquals(snapshot,after.completionTagsJson);assertEquals("done",after.status)
        assertEquals(done.revision+2,after.revision)
        assertTrue(runCatching { store.saveTask(done.copy(title="旧页面覆盖"),"stale-category") }.exceptionOrNull() is TodoConflictException)
        assertFalse(store.categories().any { it.name in setOf("旧分组","旧标签") })
        val recreated=TodoStore(context,database,store.ownerKey,store.ownerEpoch)
        assertEquals(listOf("保留标签"),recreated.categories().map { it.name })
    }

    @Test fun should_rejectDeletingRecreatedCategory_andPreserveOtherOwner() = runBlocking {
        store.createCategory("group","同名")
        val old=store.categories().single()
        database.todoDao().putCategories(listOf(TodoCategory("other","group","同名",1,1)))
        assertTrue(runCatching { store.deleteCategory("group","同名",old.createdAt-1) }.isFailure)
        store.deleteCategory("group","同名",old.createdAt)
        assertEquals(1,database.todoDao().categories("other").size)
        assertTrue(store.categories().isEmpty())
    }

}
