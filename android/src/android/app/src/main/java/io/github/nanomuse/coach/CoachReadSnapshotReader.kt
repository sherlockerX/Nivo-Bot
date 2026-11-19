package io.github.nanomuse.coach

import com.openminis.app.tools.ToolExecutionResult
import java.io.File
import org.json.JSONObject

/** nanoMuse: 区分已保存主档、备用档与未保存课程结构，不把默认结构称为历史进度。 */
internal data class CoachReadSnapshot(
    val state: CoachState,
    val source: String,
    val hasSavedArchive: Boolean,
)

/** nanoMuse: 独立读取教练存档，不实例化命令服务，不升级课程，也不修复或保存文件。 */
internal class CoachReadSnapshotReader(
    private val directory: File,
    private val loadCurrentCourses: () -> List<CoachCourse>,
) {
    /** 主备均损坏时沿用存储层错误；仅确实不存在存档时构造未保存的空进度。 */
    fun read(): CoachReadSnapshot {
        val files = CoachFileStore(directory)
        val saved = files.load()
        if (saved != null) {
            return CoachReadSnapshot(saved,
                if (files.recoveredFromBackup) "saved_backup" else "saved_primary", true)
        }
        val courses = loadCurrentCourses()
        val state = CoachState(tracks = courses.map { CoachTrack(it) })
        return CoachReadSnapshot(state, "current_curriculum_without_saved_progress", false)
    }

    /** 复用现有有界查询协议并附带快照来源，查询路径不持有任何可执行写入口。 */
    fun query(arguments: String): ToolExecutionResult {
        val snapshot = read()
        val result = CoachAgentBridge(currentState = { snapshot.state }, scope = null,
            executeCommand = { _, _ -> error("Personal records are read-only") }).query(arguments)
        val output = JSONObject(result.output).put("scope", "current_account")
            .put("snapshot_source", snapshot.source).put("has_saved_archive", snapshot.hasSavedArchive)
        return ToolExecutionResult(output.toString(), result.success)
    }
}
