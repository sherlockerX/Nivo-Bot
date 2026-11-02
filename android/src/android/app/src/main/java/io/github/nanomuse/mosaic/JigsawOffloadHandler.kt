package io.github.nanomuse.mosaic

import android.content.Context
import androidx.room.withTransaction
import com.openminis.app.sandbox.NativeOffloadHandler
import com.openminis.app.sandbox.NativeOffloadRequest
import com.openminis.app.sandbox.NativeOffloadResult
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import java.time.Clock

/** 将只读日记查询接到沙盒，查询在后台线程和一个数据库快照内完成。 */
class JigsawOffloadHandler(private val context: Context) : NativeOffloadHandler {
    /** 仅返回 stdout，不输出记录到日志，也不读取图片表和文件。 */
    override fun handle(request: NativeOffloadRequest): NativeOffloadResult = try {
        runBlocking(Dispatchers.IO) {
            withTimeout(15_000L) {
                JigsawCommand(Clock.system(JigsawQuery.ZONE), ::read).execute(request.argv.drop(1))
            }
        }
    } catch (_: kotlinx.coroutines.TimeoutCancellationException) {
        NativeOffloadResult(1, "{\"error\":\"The life log query timed out. Use a smaller range and retry.\"}\n")
    } catch (_: Exception) {
        NativeOffloadResult(1, "{\"error\":\"The life log is unavailable. Reopen the app and retry.\"}\n")
    }

    private suspend fun read(start: Long, end: Long): JigsawSnapshot {
        val database = MosaicDatabase.get(context)
        return database.withTransaction {
            val dao = database.dao()
            val entries = dao.agentEntriesBetween(start, end, 5001)
            require(entries.size <= 5000) { "Too many records. Use a smaller range or --limit; no text was truncated." }
            JigsawSnapshot(entries, dao.agentDaysBetween(start, end), dao.allHabits(),
                dao.agentSchedules(), dao.agentHabitDaysBetween(start, end))
        }
    }
}
