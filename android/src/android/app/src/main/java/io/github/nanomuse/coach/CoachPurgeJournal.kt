package io.github.nanomuse.coach

import java.io.File
import java.io.FileOutputStream
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.security.MessageDigest
import java.util.UUID
import org.json.JSONObject

/** 用户已确认、即将删除聊天的全删意图。 */
data class CoachPurgeEntry(val owner: String, val chatId: String)

/** 只有聊天已消失时才恢复档案清除，禁止后台代替用户删除仍存在的聊天。 */
class CoachPurgeJournal(private val directory: File) {
    /** 删除聊天前持久化选择。 */
    @Synchronized fun put(entry: CoachPurgeEntry) {
        require(entry.chatId.isNotBlank())
        check(directory.isDirectory || directory.mkdirs())
        val destination = file(entry.chatId)
        val temporary = File(directory, "${destination.nameWithoutExtension}.pending")
        val text = JSONObject().put("owner", entry.owner).put("chatId", entry.chatId).toString()
        FileOutputStream(temporary).use { it.write(text.toByteArray(Charsets.UTF_8)); it.fd.sync() }
        Files.move(temporary.toPath(), destination.toPath(), StandardCopyOption.ATOMIC_MOVE,
            StandardCopyOption.REPLACE_EXISTING)
    }
    /** 读取未完成操作，损坏内容必须报告。 */
    @Synchronized fun entries(): List<CoachPurgeEntry> = directory.listFiles().orEmpty()
        .filter { it.extension == "json" }.sortedBy { it.name }.map { file ->
            val value = JSONObject(file.readText(Charsets.UTF_8))
            CoachPurgeEntry(value.getString("owner"), value.getString("chatId"))
        }
    /** 全部清除成功后移除记录。 */
    @Synchronized fun remove(chatId: String) {
        val destination = file(chatId)
        check(!destination.exists() || destination.delete()) { "Unable to remove pending archive deletion" }
    }

    private fun file(chatId: String): File = File(directory,
        "${UUID.nameUUIDFromBytes(chatId.toByteArray(Charsets.UTF_8))}.json")
    companion object {
        /** 重启只恢复当前账户中已经删除的会话。 */
        fun shouldPurge(entry: CoachPurgeEntry, owner: String, exists: Boolean): Boolean =
            entry.owner == owner && !exists
    }
}

/** 比较DAO中的原消息摘要，新消息和同内容重复保存不撤销自身证据。 */
object CoachSourceChange {
    /** 缺少旧记录表示正常追加，删除或内容改变才使来源失效。 */
    fun shouldInvalidate(previous: String?, replacement: String?): Boolean {
        if (previous == null) return false
        if (replacement == null) return true
        return !MessageDigest.isEqual(hash(previous), hash(replacement))
    }

    private fun hash(value: String): ByteArray =
        MessageDigest.getInstance("SHA-256").digest(value.toByteArray(Charsets.UTF_8))
}
