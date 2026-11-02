package io.github.nanomuse.mosaic

import com.openminis.app.sandbox.NativeOffloadResult
import java.time.Clock
import org.json.JSONObject

/** 只读查询需要的数据快照，不包含图片文件或路径。 */
data class JigsawSnapshot(
    val entries: List<MosaicEntry> = emptyList(),
    val days: List<MosaicDayInfo> = emptyList(),
    val habits: List<MosaicHabit> = emptyList(),
    val schedules: List<MosaicHabitSchedule> = emptyList(),
    val marks: List<MosaicHabitDay> = emptyList(),
)

/** 拼图的只读命令入口，时钟和数据源分离以验证日期边界。 */
class JigsawCommand(private val clock: Clock, private val read: suspend (Long, Long) -> JigsawSnapshot) {
    /** 解析命令并将查询结果返回 stdout。 */
    suspend fun execute(argv: List<String>): NativeOffloadResult {
        if (argv.isEmpty() || argv.any { it in setOf("help", "--help", "-h") }) return NativeOffloadResult(0, HELP)
        return try {
            val query = JigsawQuery.parse(argv, clock)
            val window = if (query.command == "stats") query.range else query.page
            val snapshot = read(window.startDay, window.endDay)
            val output = JigsawOutput(query, snapshot).render()
            require(output.toByteArray(Charsets.UTF_8).size <= MAX_OUTPUT_BYTES) {
                "Result is too large. Use a smaller date range or --limit; no text was truncated."
            }
            NativeOffloadResult(0, output + "\n")
        } catch (error: IllegalArgumentException) {
            NativeOffloadResult(2, JSONObject().put("error", error.message ?: "Invalid arguments").toString() + "\n")
        }
    }

    companion object {
        private const val MAX_OUTPUT_BYTES = 2 * 1024 * 1024
        const val HELP = """minis-jigsaw-cli: read-only Mosaic life records
Usage:
  minis-jigsaw-cli list [--start YYYY-MM-DD] [--end YYYY-MM-DD] [--days 7] [--limit 31] [--offset 0] [--format json|md]
  minis-jigsaw-cli get --date YYYY-MM-DD [--format json|md]
  minis-jigsaw-cli stats [--start YYYY-MM-DD] [--end YYYY-MM-DD] [--days 7] [--format json|md]
  minis-jigsaw-cli export [--start YYYY-MM-DD] [--end YYYY-MM-DD] [--limit 31] [--offset 0] --format json|md

Ranges include both dates, at most 366 days. --from/--to are aliases for --start/--end.
Dates default to Asia/Shanghai today and the previous 6 days. The chosen diary date is preserved.
--limit pages whole days (1..366); follow next_offset until null. Text is never shortened.
JSON includes empty days and explicit null fields. Timestamps use Asia/Shanghai.
Only text, time, mood and habits are returned. No pictures, picture metadata or paths are read.
All results go to stdout. No write/delete commands, --out, network requests or content logging.
"""
    }
}
