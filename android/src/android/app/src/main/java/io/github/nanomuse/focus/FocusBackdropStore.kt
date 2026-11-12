package io.github.nanomuse.focus

import android.content.Context
import android.graphics.BitmapFactory
import android.net.Uri
import io.github.nanomuse.account.AccountData
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.security.MessageDigest
import java.util.UUID

/** 背景目录只保存用户在系统选择器中主动选定的本地副本，不提供给AI工具。 */
class FocusBackdropStore(private val context: Context, val owner: String, private val epoch: Long) {
    private val directory = ownerDirectory(context, owner)
    private val preferences = context.getSharedPreferences("focus_visual_${ownerHash(owner)}", Context.MODE_PRIVATE)

    /** 背景元信息不含原文件名或外部URI。 */
    data class Backdrop(val id: String, val createdAt: Long)

    /** 列表排除损坏或已删除的本地文件。 */
    suspend fun list(): List<Backdrop> = guarded {
        read().filter { file(it.id)?.isFile == true }
    }

    /** 按当前账号返回唯一受控路径，任意路径输入不能穿越目录。 */
    fun file(id: String?): File? = id?.takeIf { it.matches(Regex("[a-f0-9-]{36}")) }
        ?.let { File(directory, "$it.image") }

    /** 复制有界的用户选择，验证尺寸后再登记；失败不留下半文件。 */
    suspend fun importBackground(uri: Uri): Backdrop = withContext(Dispatchers.IO) {
        require(uri.scheme == "content")
        val id = UUID.randomUUID().toString()
        val target = checkNotNull(file(id))
        val temporary = File(context.cacheDir, "focus-import-$id")
        try {
            checkNotNull(context.contentResolver.openInputStream(uri)).use { input ->
                temporary.outputStream().use { output ->
                    val buffer = ByteArray(32 * 1024)
                    var count = 0L
                    while (true) {
                        val size = input.read(buffer)
                        if (size < 0) break
                        count += size
                        require(count <= MAX_FILE_BYTES) { "background_too_large" }
                        output.write(buffer, 0, size)
                    }
                }
            }
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeFile(temporary.path, bounds)
            require(bounds.outWidth in 1..16_384 && bounds.outHeight in 1..16_384 &&
                bounds.outWidth.toLong() * bounds.outHeight <= 100_000_000) { "unsupported_background" }
            guarded {
                val rows = read()
                require(rows.size < MAX_BACKGROUNDS) { "background_limit" }
                directory.mkdirs()
                val row = Backdrop(id, System.currentTimeMillis())
                try {
                    check(temporary.renameTo(target) || run { temporary.copyTo(target); temporary.delete() })
                    save(rows + row)
                } catch (failure: Exception) { target.delete(); throw failure }
                row
            }
        } finally { temporary.delete() }
    }

    /** 删除应用副本，不删除用户图库原图；当前背景自动回退到矢量场景。 */
    suspend fun delete(id: String) = guarded {
        val rows = read()
        if (rows.none { it.id == id }) return@guarded
        val editor = preferences.edit().putString("items", encode(rows.filterNot { it.id == id }))
        if (preferences.getString("selected", null) == id) editor.remove("selected")
        if (preferences.getString("sessionBackground", null) == id) editor.remove("sessionBackground")
        check(editor.commit())
        file(id)?.delete()
    }

    /** 读取上次选择，仍可在每次开始前更改。 */
    suspend fun selected(): String? = guarded { preferences.getString("selected", null)?.takeIf { file(it)?.exists() == true } }

    /** 选择只影响以后开始的任务。 */
    suspend fun select(id: String?) = guarded {
        require(id == null || read().any { it.id == id } && file(id)?.exists() == true)
        check(preferences.edit().putString("selected", id).commit())
    }

    /** 绑定一次会话与背景，系统重建时不用重新询问。 */
    suspend fun bind(sessionId: String) = guarded {
        check(preferences.edit().putString("session", sessionId)
            .putString("sessionBackground", preferences.getString("selected", null)).commit())
    }

    /** 恢复当前会话的背景；AI开始的计时默认采用矢量背景。 */
    suspend fun backgroundFor(sessionId: String): File? = guarded {
        if (preferences.getString("session", null) != sessionId) null
        else file(preferences.getString("sessionBackground", null))?.takeIf { it.exists() }
    }

    /** 记住用户主动进入的全屏会话，进程重启后可恢复；主动收起时清除。 */
    suspend fun rememberImmersive(sessionId: String?) = guarded {
        check(preferences.edit().putString("immersiveSession", sessionId).commit())
    }

    /** 不凭此字段启动计时，恢复前必须核对Room中仍存在同一会话。 */
    suspend fun immersiveSession(): String? = guarded { preferences.getString("immersiveSession", null) }

    /** 常亮属于用户选择，不主动改变系统锁屏。 */
    fun keepScreenOn(): Boolean = preferences.getBoolean("keepScreenOn", false)
    /** 更新当前账号的常亮偏好。 */
    suspend fun setKeepScreenOn(value: Boolean) = guarded {
        check(preferences.edit().putBoolean("keepScreenOn", value).commit())
    }

    private fun read(): List<Backdrop> {
        val array = JSONArray(preferences.getString("items", "[]"))
        return (0 until array.length()).map { index -> array.getJSONObject(index).let { Backdrop(it.getString("id"), it.getLong("createdAt")) } }
    }
    private fun encode(rows: List<Backdrop>): String = JSONArray(rows.map { JSONObject().put("id", it.id).put("createdAt", it.createdAt) }).toString()
    private fun save(rows: List<Backdrop>) { check(preferences.edit().putString("items", encode(rows)).commit()) }
    private suspend fun <T> guarded(block: () -> T): T = withContext(Dispatchers.IO) {
        AccountData.withTodoOwnerMutation(owner, epoch) { block() }
    }

    companion object {
        const val MAX_BACKGROUNDS = 24
        const val MAX_FILE_BYTES = 20L * 1024 * 1024
        private fun ownerHash(owner: String): String = MessageDigest.getInstance("SHA-256").digest(owner.toByteArray()).joinToString("") { "%02x".format(it) }
        private fun ownerDirectory(context: Context, owner: String) = File(context.filesDir, "focus-backgrounds/${ownerHash(owner)}")
        /** 已持账号迁移锁时，仅清除此账号自己导入的文件。 */
        fun deleteOwner(context: Context, owner: String) {
            ownerDirectory(context, owner).listFiles()?.filter { it.isFile && it.name.endsWith(".image") }?.forEach { it.delete() }
            context.getSharedPreferences("focus_visual_${ownerHash(owner)}", Context.MODE_PRIVATE).edit().clear().commit()
        }
    }
}
