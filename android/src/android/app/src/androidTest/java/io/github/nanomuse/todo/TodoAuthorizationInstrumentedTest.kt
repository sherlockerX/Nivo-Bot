package io.github.nanomuse.todo

import android.content.Context
import androidx.room.Room
import androidx.room.withTransaction
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import io.github.nanomuse.account.AccountData
import io.github.nanomuse.coach.CoachTurnAuthorization
import io.github.nanomuse.mosaic.MosaicDatabase
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/** 从宿主工具走真实Room事务，核验撤权时任务、事件和幂等记录整体回滚。 */
@RunWith(AndroidJUnit4::class)
class TodoAuthorizationInstrumentedTest {
    private lateinit var database: MosaicDatabase
    private lateinit var store: TodoStore
    private val authorization = CoachTurnAuthorization("user", "main", "token")
    private val allowed = TodoToolAccess(
        isAccountCurrent = true, isMain = true, isScheduled = false, isTaskDispatch = false,
        sessionId = "main", loopUserId = "user", authorization = authorization,
        currentAuthorization = authorization, user = TodoToolUser("user", "这条任务已经完成了", "main"),
    )

    /** 使用隔离测试包和内存数据库，避免碰到用户的实际待办。 */
    @Before fun prepare() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        check(context.packageName.endsWith(".uitest")) { "只允许隔离测试包" }
        database = Room.inMemoryDatabaseBuilder(context, MosaicDatabase::class.java).build()
        store = TodoStore(context, database, AccountData.key(context), AccountData.epoch.value)
    }

    /** 每个用例结束释放内存数据库。 */
    @After fun close() { database.close() }

    @Test fun should_rejectQueuedToolWrite_when_mainChatChangesWhileRoomIsBusy() = runBlocking {
        withTimeout(10_000) {
            val before = snapshot()
            val occupied = CompletableDeferred<Unit>()
            val release = CompletableDeferred<Unit>()
            val enteredStorage = CompletableDeferred<Unit>()
            var access = allowed
            val adapter = TodoStoreToolStorage(store)
            val storage = object : TodoToolStorage by adapter {
                override suspend fun saveTask(task: TodoTask, operationId: String): TodoTask {
                    enteredStorage.complete(Unit)
                    return adapter.saveTask(task, operationId)
                }
            }
            val blocker = async {
                database.withTransaction { occupied.complete(Unit); release.await() }
            }
            occupied.await()
            val result = async {
                TodoToolHost({ access }, { _, _ -> null }, { storage }).execute(
                    TodoAgentBridge.COMMAND,
                    JSONObject().put("action", "create").put("operationId", "queued-create")
                        .put("payload", """{"title":"等待期间已撤权"}""").toString(),
                )
            }
            try {
                enteredStorage.await()
                assertFalse(result.isCompleted)
                access = allowed.copy(isMain = false)
            } finally {
                release.complete(Unit)
            }
            blocker.await()
            val rejected = result.await()
            assertFalse(rejected.output, rejected.success)
            assertTrue(rejected.output, rejected.output.contains("main_required"))
            assertEquals(before, snapshot())
        }
    }

    @Test fun should_rollbackEveryToolMutation_when_accessRevokesBeforeCommit() = runBlocking {
        withTimeout(10_000) {
            val task = store.saveTask(TodoTask(ownerKey = store.ownerKey, title = "保留原任务", groupName = "原分组"), "seed")
            val category = store.categories().single { it.name == "原分组" }
            val requests = listOf(
                JSONObject().put("action", "create").put("payload", """{"title":"不应新增","groupName":"新分组"}"""),
                JSONObject().put("action", "update").put("payload", """{"title":"不应覆盖"}"""),
                JSONObject().put("action", "start"),
                JSONObject().put("action", "complete").put("userQuote", allowed.user!!.text),
                JSONObject().put("action", "delete"),
                JSONObject().put("action", "create_category").put("categoryKind", "group").put("categoryName", "新分类"),
                JSONObject().put("action", "delete_category").put("categoryKind", "group").put("categoryName", category.name)
                    .put("expectedCreatedAt", category.createdAt),
            )
            for (request in requests) {
                val action = request.getString("action")
                val operationId = "revoked-$action"
                request.put("operationId", operationId)
                if (action in setOf("update", "start", "complete", "delete")) {
                    request.put("targetId", task.id).put("expectedRevision", task.revision)
                }
                val before = snapshot()
                var isRevoked = false
                val host = TodoToolHost({
                    // DAO直接读取当前事务内的新幂等行；不重新进入账号互斥锁。
                    isRevoked = isRevoked || database.todoDao().operation(store.ownerKey, operationId) != null
                    if (isRevoked) allowed.copy(currentAuthorization = null) else allowed
                }, { _, _ -> null }, { TodoStoreToolStorage(store) })
                val result = host.execute(TodoAgentBridge.COMMAND, request.toString())
                assertTrue("${action}必须到达写入后的授权校验", isRevoked)
                assertFalse("$action: ${result.output}", result.success)
                assertEquals("${action}必须回滚全部记录", before, snapshot())
            }
        }
    }

    private suspend fun snapshot(): List<Any> = database.todoDao().let { dao -> listOf(
        dao.allTasks(store.ownerKey), dao.categories(store.ownerKey),
        dao.events(store.ownerKey), dao.operations(store.ownerKey),
    ) }
}
