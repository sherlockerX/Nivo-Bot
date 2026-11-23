package io.github.nanomuse.chat

import android.content.Context
import android.net.Uri
import android.provider.OpenableColumns
import com.openminis.app.logging.AppLogger
import java.io.File
import java.io.FilterInputStream
import java.io.IOException
import java.io.InputStream
import java.util.Collections

/** 附件超过上限；[isBatch]为真表示这条消息的附件合计超过[limitBytes]，否则是单个附件超过。 */
class AttachmentTooLargeException(val limitBytes: Long, val isBatch: Boolean) :
    IOException("attachment exceeds $limitBytes bytes")

/**
 * 一条消息的附件接收：读取前先看大小，读取中按上限截止，并记下已写出的文件。
 * 来源不给出大小时（部分内容提供方如此），由读取中的上限兜底。
 */
class AttachmentIntake(
    private val context: Context,
    private val isActive: () -> Boolean,
) {
    private val written: MutableList<File> = Collections.synchronizedList(mutableListOf())
    private var remaining = MAX_BATCH_BYTES

    /** 打开附件，返回的流读到上限或任务取消时抛出异常；已知大小超过上限的在打开之前就拒绝。 */
    fun open(uri: Uri, isImage: Boolean): CappedInputStream {
        val single = if (isImage) MAX_IMAGE_BYTES else MAX_FILE_BYTES
        val limit = minOf(single, remaining)
        if (declaredSize(uri) > limit) throw tooLarge(single)
        val source = context.contentResolver.openInputStream(uri) ?: throw IOException("cannot open attachment")
        return CappedInputStream(source, limit, isActive) { tooLarge(single) }
    }

    private fun tooLarge(single: Long): AttachmentTooLargeException =
        if (remaining < single) AttachmentTooLargeException(MAX_BATCH_BYTES, isBatch = true)
        else AttachmentTooLargeException(single, isBatch = false)

    /** 记下已写好的文件并从整批额度里扣除；发送没有完成时由[discard]删除。 */
    fun accept(file: File) {
        written += file
        remaining = (remaining - file.length()).coerceAtLeast(0)
    }

    /** 在应用内再放一份副本，失败或取消时不留半个文件。 */
    fun mirror(source: File, target: File) {
        var isDone = false
        try {
            CappedInputStream(source.inputStream(), Long.MAX_VALUE, isActive) { IOException("copy too large") }.use { input ->
                target.outputStream().use { output -> input.copyTo(output, COPY_BUFFER_BYTES) }
            }
            written += target
            isDone = true
        } finally {
            if (!isDone) target.delete()
        }
    }

    /** 删除这次写出的全部文件。 */
    fun discard() {
        val files = synchronized(written) { written.toList().also { written.clear() } }
        for (file in files) if (file.exists() && !file.delete()) AppLogger.warning(TAG, "could not delete ${file.name}")
    }

    private fun declaredSize(uri: Uri): Long {
        if (uri.scheme == "file") return uri.path?.let { File(it).length() } ?: UNKNOWN_SIZE
        return runCatching {
            context.contentResolver.query(uri, arrayOf(OpenableColumns.SIZE), null, null, null)?.use { cursor ->
                if (cursor.moveToFirst() && !cursor.isNull(0)) cursor.getLong(0) else UNKNOWN_SIZE
            }
        }.getOrNull() ?: UNKNOWN_SIZE
    }

    companion object {
        /** 单张原图；解码后的推理图另有上限。 */
        const val MAX_IMAGE_BYTES = 100L * 1024 * 1024

        /** 单个文件；文件只流式落盘，不进内存。 */
        const val MAX_FILE_BYTES = 1024L * 1024 * 1024

        /** 一条消息的全部附件。 */
        const val MAX_BATCH_BYTES = 1536L * 1024 * 1024

        private const val UNKNOWN_SIZE = -1L
        private const val COPY_BUFFER_BYTES = 64 * 1024
        private const val TAG = "AttachmentIntake"
    }
}

/** 最多读[limit]字节的流；多出一个字节就抛出，不会把截断的内容当成完整文件。 */
class CappedInputStream(
    source: InputStream,
    private val limit: Long,
    private val isActive: () -> Boolean,
    private val overflow: () -> IOException,
) : FilterInputStream(source) {
    private var total = 0L

    /** 超限或取消时的原因，供吞掉异常的复制方判断。 */
    var failure: IOException? = null
        private set

    override fun read(): Int {
        checkActive()
        val value = super.read()
        if (value >= 0) count(1)
        return value
    }

    override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
        checkActive()
        val size = super.read(buffer, offset, length)
        if (size > 0) count(size.toLong())
        return size
    }

    override fun markSupported(): Boolean = false

    private fun checkActive() {
        if (!isActive()) throw IOException("attachment copy cancelled").also { failure = it }
    }

    private fun count(bytes: Long) {
        total += bytes
        if (total > limit) throw overflow().also { failure = it }
    }
}
