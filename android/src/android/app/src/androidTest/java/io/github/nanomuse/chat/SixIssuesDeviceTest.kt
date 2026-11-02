package io.github.nanomuse.chat

import androidx.room.Room
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.openminis.app.data.db.AppDatabase
import com.openminis.app.data.db.ChatSessionEntity
import com.openminis.app.data.repository.ChatRepository
import com.openminis.app.sandbox.NativeOffloadRequest
import com.openminis.app.sandbox.offload.SessionsOffloadHandler
import io.github.nanomuse.routines.*
import kotlinx.coroutines.*
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.util.UUID

/** 使用隔离内存数据库验证真实SQLite、文件系统与CLI契约，不调用模型。 */
@RunWith(AndroidJUnit4::class)
class SixIssuesDeviceTest {
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private lateinit var database: AppDatabase
    private lateinit var home: File

    /** 只允许隔离测试包，不读取正式应用数据。 */
    @Before fun prepare() {
        check(context.packageName.endsWith(".uitest"))
        database = Room.inMemoryDatabaseBuilder(context, AppDatabase::class.java).build()
        home = File(context.cacheDir, "six-issues-${UUID.randomUUID()}").also { check(it.mkdirs()) }
    }

    /** 仅清理本测试创建的内存数据库和缓存目录。 */
    @After fun cleanup() {
        if (::database.isInitialized) database.close()
        if (::home.isInitialized && home.canonicalPath.startsWith(context.cacheDir.canonicalPath + File.separator)) home.deleteRecursively()
    }

    @Test fun should_preserveSingleGroup_when_creatingConcurrentNormalizedNames() = runBlocking {
        val repository = ChatRepository(database.chatDao())
        val results = (1..12).map { index -> async(Dispatchers.IO) {
            runCatching { repository.createFolder(if (index % 2 == 0) " Ｓｔｒａｓｓｅ " else "Straße") }
        } }.awaitAll()
        val group = results.single { it.isSuccess }.getOrThrow()
        results.filter { it.isFailure }.forEach {
            val error = it.exceptionOrNull() as GroupNameException
            assertEquals("GROUP_NAME_EXISTS", error.code)
            assertEquals(group.id, error.existingGroupId)
        }
        repository.renameFolder(group.id, "STRASSE")
        assertEquals("STRASSE", database.chatDao().getFolder(group.id)?.name)
        assertEquals(group.id, database.chatDao().folderByNameKey("strasse")?.id)
    }

    @Test fun should_returnStableTextAndTruncatedFlags_when_reading200SavedMessages() = runBlocking {
        val dao = database.chatDao()
        val repository = ChatRepository(dao)
        val sessionId = "synthetic-session"
        dao.insertSession(ChatSessionEntity(id = sessionId, modelId = "fixture", createdAt = 1, updatedAt = 1))
        val expected = "x".repeat(719)
        repeat(200) { index ->
            assertEquals(719L, ScheduledOutputWriter.write(repository, sessionId,
                ScheduledRunScope("synthetic-task"), "assistant", expected))
            assertEquals(index + 1, dao.loadMessages(sessionId).size)
        }
        val handler = SessionsOffloadHandler(repository)
        var inspected = 0
        for (offset in 0 until 200 step 20) {
            val result = handler.handle(NativeOffloadRequest(0,
                listOf("minis-sessions-cli", "messages", "--id", sessionId, "--offset", offset.toString(), "--limit", "20", "--full", "--compact"), emptyMap(), "/"))
            assertEquals(0, result.exitCode)
            val messages = JSONObject(result.output).getJSONObject("data").getJSONArray("messages")
            repeat(messages.length()) { index ->
                val message = messages.getJSONObject(index)
                assertEquals(expected, message.getString("text"))
                assertFalse(message.getBoolean("truncated"))
                inspected++
            }
        }
        assertEquals(200, inspected)
    }

    @Test fun should_keepPrivateLogsAndRejectSymlinks_when_usingDeviceFilesystem() {
        val journal = ScheduledRunJournal(home)
        val run = JSONObject().put("run_id", "first").put("started_at_ms", System.currentTimeMillis())
        journal.write("task", run, JSONObject())
        val directory = File(home, "logs/scheduled/task")
        val log = directory.listFiles()!!.single()
        assertEquals(448, android.system.Os.stat(directory.path).st_mode and 511)
        assertEquals(384, android.system.Os.stat(log.path).st_mode and 511)
        assertEquals(384, android.system.Os.stat(File(home, "state/scheduled/task.json").path).st_mode and 511)
        val outside = File(home, "unrelated.txt").also { it.writeText("not a log") }
        val link = File(directory, "2099-01-01.jsonl")
        android.system.Os.symlink(outside.path, link.path)
        assertEquals(1, journal.query("task").getJSONArray("runs").length())
        assertEquals("not a log", outside.readText())
    }

    @Test fun should_extractRealDeviceTimezone_withoutNetworkOrRootfsBoot() {
        val archive = File("/apex/com.android.tzdata/etc/tz/tzdata")
        val bytes = requireNotNull(ScheduledTimezone.extract(archive, "Asia/Shanghai"))
        assertEquals("TZif", String(bytes, 0, 4, Charsets.US_ASCII))
        assertTrue(bytes.size > 44)
    }

    @Test fun should_bindReportCapabilityToActualProcess_when_runningOnAndroid() {
        val process = ProcessBuilder("/system/bin/sh", "-c", "sleep 5").start()
        try {
            val pid = requireNotNull(ScheduledProcessIdentity.pid(process))
            val scope = ScheduledRunScope("synthetic-task")
            scope.registerProcess(pid)
            assertTrue(scope.authentic(scope.environment(), pid))
            assertFalse(scope.authentic(scope.environment(), android.os.Process.myPid()))
            assertFalse(scope.authentic(scope.environment() - "MINIS_RUN_TOKEN", pid))
        } finally { process.destroyForcibly() }
    }

    @Test fun should_expireOrphanLogsOnDevice_withoutDeletingUnrelatedFiles() {
        val directory = File(home, "logs/scheduled/deleted-task").also { check(it.mkdirs()) }
        val expired = File(directory, "2000-01-01.jsonl").also { it.writeText("{}\n") }
        val unrelated = File(home, "logs/unrelated.txt").also { it.writeText("keep") }
        ScheduledRunJournal(home).maintain()
        assertFalse(expired.exists())
        assertEquals("keep", unrelated.readText())
        assertFalse(File(home, "state/scheduled/deleted-task.json").exists())
    }
}
