package io.github.nanomuse.coach

import java.io.File
import java.io.FileOutputStream
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.security.MessageDigest
import org.json.JSONObject

/** 首次入队即固定账户、原文版本、课次和数据库顺序，重试不能重新绑定。 */
data class CoachArchiveEntry(
    val chatId: String, val messageId: String, val lessonId: String,
    val role: String, val text: String, val sourceHash: String,
    val sortOrder: Int, val owner: String,
)

/** 损坏项与健康项分别返回，调用方可继续整理其余消息并保留全部错误。 */
data class CoachArchiveRead(
    val entries: List<CoachArchiveEntry>, val errors: List<String>,
)

/** 聊天按摘要分目录，所有实例共用文件锁，单项损坏不会影响其他聊天。 */
class CoachArchiveOutbox(private val directory: File) {
    companion object {
        private val FILE_LOCK = Any()
        private val MESSAGE_ID = Regex("[A-Za-z0-9_-]+")
    }

    /** 相同来源重复入队只返回首次记录；变更的原文或所有者必须先显式失效。 */
    fun put(entry: CoachArchiveEntry): CoachArchiveEntry = synchronized(FILE_LOCK) {
        validateId(entry.messageId)
        require(entry.role in setOf("user", "assistant")) { "Unsupported archive message role" }
        val folder = chatDirectory(entry.chatId)
        check(folder.isDirectory || folder.mkdirs()) { "Unable to create the archive retry directory" }
        val destination = File(folder, "${entry.messageId}.json")
        if (destination.exists()) {
            val original = readEntry(destination, entry.chatId)
            require(original.sourceHash == entry.sourceHash && original.text == entry.text &&
                original.role == entry.role && original.owner == entry.owner) {
                "The original archive source or owner changed"
            }
            return@synchronized original
        }
        val temporary = File(folder, "${entry.messageId}.pending")
        val value = JSONObject().put("chatId", entry.chatId).put("messageId", entry.messageId)
            .put("lessonId", entry.lessonId).put("role", entry.role).put("text", entry.text)
            .put("sourceHash", entry.sourceHash).put("sortOrder", entry.sortOrder).put("owner", entry.owner)
            .toString()
        FileOutputStream(temporary).use { it.write(value.toByteArray(Charsets.UTF_8)); it.fd.sync() }
        Files.move(temporary.toPath(), destination.toPath(), StandardCopyOption.ATOMIC_MOVE,
            StandardCopyOption.REPLACE_EXISTING)
        entry
    }

    /** 按原数据库顺序恢复，mtime和重复写入不会改变用户问题与回答的先后关系。 */
    fun read(chatId: String): CoachArchiveRead = synchronized(FILE_LOCK) {
        val entries = mutableListOf<CoachArchiveEntry>()
        val errors = mutableListOf<String>()
        try {
            recordFiles(chatId).filter { it.extension == "json" }.forEach { file ->
                try {
                    entries += readEntry(file, chatId)
                } catch (failure: Exception) {
                    errors += "${file.name}: ${failure.message ?: "Unable to read archive retry record"}"
                }
            }
        } catch (failure: Exception) {
            errors += failure.message ?: "Unable to read archive retry directory"
        }
        CoachArchiveRead(entries.sortedWith(compareBy<CoachArchiveEntry> { it.sortOrder }.thenBy { it.messageId }), errors)
    }

    /** 严格读取供完整性检查使用，生产重试使用read逐项恢复。 */
    fun entries(chatId: String): List<CoachArchiveEntry> {
        val result = read(chatId)
        check(result.errors.isEmpty()) { result.errors.joinToString("\n") }
        return result.entries
    }

    /** 仅删除指定聊天的已提交消息，不解析或触碰其他聊天的待办。 */
    fun remove(chatId: String, messageId: String) = synchronized(FILE_LOCK) {
        validateId(messageId)
        deleteRecord(File(chatDirectory(chatId), "$messageId.json"))
    }

    /** 来源明确删除时连同损坏记录和未提交临时文件一起清除，不需要先解析JSON。 */
    fun forget(chatId: String, messageId: String? = null) = synchronized(FILE_LOCK) {
        if (messageId != null) {
            validateId(messageId)
            val folder = chatDirectory(chatId)
            deleteRecord(File(folder, "$messageId.json"))
            deleteRecord(File(folder, "$messageId.pending"))
        } else {
            recordFiles(chatId).filter { it.extension in setOf("json", "pending") }.forEach(::deleteRecord)
        }
    }

    private fun readEntry(file: File, chatId: String): CoachArchiveEntry {
        val value = JSONObject(file.readText(Charsets.UTF_8))
        val entry = CoachArchiveEntry(value.getString("chatId"), value.getString("messageId"),
            value.getString("lessonId"), value.getString("role"), value.getString("text"),
            value.getString("sourceHash"), value.getInt("sortOrder"), value.getString("owner"))
        validateId(entry.messageId)
        require(entry.chatId == chatId && entry.messageId == file.nameWithoutExtension) {
            "Archive retry record identity does not match its path"
        }
        require(entry.role in setOf("user", "assistant")) { "Unsupported archive message role" }
        return entry
    }

    private fun recordFiles(chatId: String): List<File> {
        val folder = chatDirectory(chatId)
        if (!folder.exists()) return emptyList()
        check(folder.isDirectory) { "Archive retry path is not a directory" }
        return folder.listFiles()?.toList() ?: error("Unable to read archive retry directory")
    }

    private fun chatDirectory(chatId: String): File {
        require(chatId.isNotBlank()) { "A conversation ID is required" }
        val digest = MessageDigest.getInstance("SHA-256").digest(chatId.toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it) }
        return File(directory, digest)
    }

    private fun validateId(messageId: String) {
        require(messageId.matches(MESSAGE_ID)) { "Invalid archive message ID" }
    }

    private fun deleteRecord(file: File) {
        check(!file.exists() || (file.isFile && file.delete())) { "Unable to clear the archive retry record" }
    }
}
