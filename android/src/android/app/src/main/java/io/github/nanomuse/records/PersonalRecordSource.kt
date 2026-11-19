package io.github.nanomuse.records

import android.content.Context
import com.openminis.app.scheduled.ScheduledTask
import com.openminis.app.tools.ToolExecutionResult
import io.github.nanomuse.account.AccountData
import io.github.nanomuse.coach.CoachCurriculumRepository
import io.github.nanomuse.coach.CoachReadSnapshotReader
import io.github.nanomuse.goals.Goal
import io.github.nanomuse.mosaic.JigsawCommand
import io.github.nanomuse.mosaic.JigsawRecordsReader
import org.json.JSONObject
import java.io.File
import java.time.Clock

/** 查询端口只暴露领域记录，不让模型指定数据库、首选项或文件路径。 */
internal interface PersonalRecordSource {
    suspend fun reflections(arguments: List<String>): ToolExecutionResult
    suspend fun reflectionRange(): JSONObject
    suspend fun coach(arguments: String): ToolExecutionResult
    suspend fun goals(): List<Goal>
    suspend fun routines(): List<ScheduledTask>
}

/** 固定发起账户代次，所有同步文件读取都与账户迁移互斥。 */
internal class AndroidPersonalRecordSource(private val context: Context) : PersonalRecordSource {
    private val operation = AccountData.captureOperation()

    override suspend fun reflections(arguments: List<String>): ToolExecutionResult {
        operation.requireCurrent()
        val result = JigsawCommand(Clock.systemDefaultZone(), JigsawRecordsReader(context)::read).execute(arguments)
        operation.requireCurrent()
        val output = JSONObject(result.output).put("success", result.exitCode == 0)
            .put("scope", "device_local").put("view_url", "minis://views/mosaic")
        return ToolExecutionResult(output.toString(), result.exitCode == 0)
    }

    override suspend fun reflectionRange(): JSONObject {
        operation.requireCurrent()
        return JigsawRecordsReader(context).range().also { operation.requireCurrent() }
    }

    override suspend fun coach(arguments: String): ToolExecutionResult = operation.files {
        // nanoMuse: 命令服务首次初始化会升级并保存课程；记录查询只读取原存档。
        val directory = File(context.filesDir, "minis-global/nanomuse/growth/coach-v2")
        CoachReadSnapshotReader(directory) { CoachCurriculumRepository.load(context) }.query(arguments)
    }

    override suspend fun goals(): List<Goal> = operation.files {
        val file = File(context.filesDir, "minis-global/nanomuse/goals.json")
        if (!file.exists()) return@files emptyList()
        require(file.length() <= MAX_SOURCE_BYTES) { "Goal archive is too large to query" }
        PersonalRecordDecoding.goals(file.readText(Charsets.UTF_8))
    }

    override suspend fun routines(): List<ScheduledTask> = operation.files {
        // 直接读取既有存储协议，避免构造管理器时触发迁移或重新安排闹钟。
        val raw = context.getSharedPreferences("minis_scheduled_tasks_prefs", Context.MODE_PRIVATE)
            .getString("tasks_json", null) ?: return@files emptyList()
        require(raw.length <= MAX_SOURCE_BYTES) { "Routine archive is too large to query" }
        PersonalRecordDecoding.routines(raw)
    }

    companion object { private const val MAX_SOURCE_BYTES = 8 * 1024 * 1024L }
}
