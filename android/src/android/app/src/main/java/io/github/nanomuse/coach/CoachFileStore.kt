package io.github.nanomuse.coach

import java.io.File
import java.io.FileOutputStream
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

/** 独立快照保留上一有效版本；损坏时不以空数据覆盖用户证据。 */
class CoachFileStore(private val directory: File) {
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    private val primary get() = File(directory, "state.json")
    private val backup get() = File(directory, "state.backup.json")
    var recoveredFromBackup: Boolean = false
        private set

    /** 首次安装返回空值，已有数据全部损坏则拒绝继续写入。 */
    fun load(): CoachState? {
        if (!primary.exists() && !backup.exists()) return null
        decode(primary)?.let { return it }
        decode(backup)?.let { recoveredFromBackup = true; return it }
        throw IllegalStateException("Coach records could not be read; existing files were preserved.")
    }

    /** fsync后同目录原子替换，只有成功提交后调用方才发布新状态。 */
    fun save(state: CoachState, forgetPreviousSnapshot: Boolean = false) {
        check(directory.isDirectory || directory.mkdirs()) { "Coach directory is not writable" }
        val temporary = File(directory, "state.pending.json")
        val bytes = json.encodeToString(state).toByteArray(Charsets.UTF_8)
        FileOutputStream(temporary).use { stream -> stream.write(bytes); stream.fd.sync() }
        check(decode(temporary) == state) { "Coach snapshot validation failed" }
        if (forgetPreviousSnapshot) {
            // 用户删除摘录时备份也必须清除；先写入同一份有效新快照，再替换主文件。
            Files.copy(temporary.toPath(), backup.toPath(), StandardCopyOption.REPLACE_EXISTING)
        } else if (decode(primary) != null) {
            Files.copy(primary.toPath(), backup.toPath(), StandardCopyOption.REPLACE_EXISTING)
        }
        Files.move(temporary.toPath(), primary.toPath(), StandardCopyOption.REPLACE_EXISTING,
            StandardCopyOption.ATOMIC_MOVE)
        recoveredFromBackup = false
    }

    private fun decode(file: File): CoachState? = runCatching {
        json.decodeFromString<CoachState>(file.readText(Charsets.UTF_8)).also {
            require(it.schemaVersion in 2..3 && it.revision >= 0)
            require(it.tracks.map { track -> track.course.id }.distinct().size == it.tracks.size)
            require(it.sessions.map { session -> session.id }.distinct().size == it.sessions.size)
            require(it.topics.map { topic -> topic.id }.distinct().size == it.topics.size)
            val boundChats = it.topics.map { topic -> topic.chatSessionId }.filter(String::isNotBlank)
            require(boundChats.distinct().size == boundChats.size)
        }
    }.getOrNull()
}
