package io.github.nanomuse.routines

import android.content.Context
import com.openminis.app.sandbox.RootfsManager
import java.io.File
import java.io.RandomAccessFile
import java.time.ZoneId

/** 从设备公共时区库提供当前区域的TZif，旧镜像不再因缺少tzdata退回UTC。 */
object ScheduledTimezone {
    private val archives = listOf("/apex/com.android.tzdata/etc/tz/tzdata", "/system/usr/share/zoneinfo/tzdata", "/data/misc/zoneinfo/current/tzdata")

    /** 只读检查，不创建目录、不执行解释器或安装依赖。 */
    fun available(context: Context): Boolean {
        val zone = ZoneId.systemDefault()
        if (zone.rules.isFixedOffset && zone.rules.getOffset(java.time.Instant.now()).totalSeconds == 0) return true
        if (File(RootfsManager.getInstance(context).rootfsDir, "usr/share/zoneinfo/${zone.id}").isFile) return true
        return source(zone.id) != null
    }

    /** 执行前准备独立绑定目录，系统TZ变量仍使用设备IANA名称。 */
    @Synchronized fun prepare(context: Context): File? {
        val zone = ZoneId.systemDefault().id
        val rootfs = RootfsManager.getInstance(context).rootfsDir
        if (File(rootfs, "usr/share/zoneinfo/$zone").isFile) return null
        val data = source(zone) ?: return null
        val home = File(context.filesDir, "minis-global/home").canonicalFile
        val directory = File(home, "state/timezones").absoluteFile
        val target = File(directory, zone).absoluteFile
        require(directory.canonicalFile == directory && target.canonicalFile == target && target.toPath().startsWith(directory.toPath())) { "TIMEZONE_PATH_INVALID" }
        check(target.parentFile!!.isDirectory || target.parentFile!!.mkdirs()) { "TIMEZONE_DIRECTORY_FAILED" }
        if (!target.isFile || !target.readBytes().contentEquals(data)) target.writeBytes(data)
        target.setReadable(false, false); target.setReadable(true, true)
        target.setWritable(false, false); target.setWritable(true, true)
        File(rootfs, "usr/share/zoneinfo").mkdirs()
        return directory
    }

    private fun source(zone: String): ByteArray? = archives.firstNotNullOfOrNull { path -> runCatching { extract(File(path), zone) }.getOrNull() }

    /** 读取Android归档的固定长度索引，不依赖隐藏API或任意脚本。 */
    internal fun extract(file: File, zone: String): ByteArray? = RandomAccessFile(file, "r").use { input ->
        val header = ByteArray(12).also(input::readFully)
        require(String(header, 0, 6, Charsets.US_ASCII) == "tzdata") { "INVALID_TZ_ARCHIVE" }
        val index = input.readInt()
        val data = input.readInt()
        val end = input.readInt()
        require(index >= 24 && data > index && end > data && end <= input.length() && (data - index) % 52 == 0) { "INVALID_TZ_ARCHIVE" }
        input.seek(index.toLong())
        repeat((data - index) / 52) {
            val name = ByteArray(40).also(input::readFully).takeWhile { it != 0.toByte() }.toByteArray().toString(Charsets.US_ASCII)
            val offset = input.readInt()
            val length = input.readInt()
            input.readInt()
            if (name == zone) return@use readZone(input, data, end, offset, length)
        }
        null
    }

    private fun readZone(input: RandomAccessFile, data: Int, end: Int, offset: Int, length: Int): ByteArray {
        require(offset >= 0 && length in 44..2_000_000 && data.toLong() + offset + length <= end) { "INVALID_TZ_ENTRY" }
        input.seek(data.toLong() + offset)
        val bytes = ByteArray(length).also(input::readFully)
        require(String(bytes, 0, 4, Charsets.US_ASCII) == "TZif") { "INVALID_TZ_ENTRY" }
        return bytes
    }
}
