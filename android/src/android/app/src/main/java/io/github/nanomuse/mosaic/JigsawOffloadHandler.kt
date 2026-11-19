package io.github.nanomuse.mosaic

import android.content.Context
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
                // nanoMuse: 每次调用重新固定账号凭证，注册时创建的处理器可以跨账号继续使用。
                val reader = JigsawRecordsReader(context)
                JigsawCommand(Clock.systemDefaultZone(), reader::read).execute(request.argv.drop(1))
            }
        }
    } catch (_: kotlinx.coroutines.TimeoutCancellationException) {
        NativeOffloadResult(1, "{\"error\":\"The life log query timed out. Use a smaller range and retry.\"}\n")
    } catch (_: Exception) {
        NativeOffloadResult(1, "{\"error\":\"The life log is unavailable. Reopen the app and retry.\"}\n")
    }
}
