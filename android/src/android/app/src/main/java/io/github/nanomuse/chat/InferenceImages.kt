package io.github.nanomuse.chat

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import com.openminis.app.logging.AppLogger
import com.openminis.app.provider.ImageBudget
import java.io.ByteArrayOutputStream
import java.io.File

/** 给模型用的图片：原图留在磁盘，这里只有尺寸和字节都受限的副本。 */
class InferenceImage(val bytes: ByteArray, val mimeType: String, val isRecompressed: Boolean = false)

/**
 * 从文件生成[InferenceImage]。先读像素尺寸再按比例解码，内存占用由目标边长决定，与原图大小无关。
 * 结果缓存在[cacheDir]，重开会话时不再重复解码；[cacheDir]为空时不缓存。
 */
class InferenceImages(private val cacheDir: File?) {

    /** 无法解码且原文件也超过单图上限时返回空，调用方改用文字占位。 */
    fun load(file: File, mimeType: String): InferenceImage? {
        if (!file.isFile) return null
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(file.path, bounds)
        val isDecodable = bounds.outWidth > 0 && bounds.outHeight > 0
        val longEdge = maxOf(bounds.outWidth, bounds.outHeight)
        val isSmallFile = file.length() <= ImageBudget.MAX_PER_IMAGE_BYTES
        if (isSmallFile && (!isDecodable || longEdge <= ImageBudget.MAX_EDGE_PX)) {
            return read(file)?.let { InferenceImage(it, mimeType) }
        }
        if (!isDecodable) return null
        cached(file)?.let { return it }
        return encode(file, longEdge, isPng = mimeType.contains("png"))?.also { store(file, it) }
    }

    private fun encode(file: File, longEdge: Int, isPng: Boolean): InferenceImage? {
        var isRecompressed = false
        for ((edge, quality) in LADDER) {
            val bitmap = decode(file, longEdge, edge) ?: return null
            try {
                // 截图等PNG先保留无损格式，超过单图上限再转JPEG。
                if (isPng && edge == ImageBudget.MAX_EDGE_PX) {
                    val png = compress(bitmap, Bitmap.CompressFormat.PNG, 100)
                    if (png.size <= ImageBudget.MAX_PER_IMAGE_BYTES) return InferenceImage(png, "image/png")
                    isRecompressed = true
                }
                val jpeg = compress(bitmap, Bitmap.CompressFormat.JPEG, quality)
                if (jpeg.size <= ImageBudget.MAX_PER_IMAGE_BYTES) return InferenceImage(jpeg, "image/jpeg", isRecompressed)
                isRecompressed = true
            } finally {
                bitmap.recycle()
            }
        }
        return null
    }

    private fun decode(file: File, longEdge: Int, edge: Int): Bitmap? {
        var sample = 1
        while (longEdge / (sample * 2) >= edge) sample *= 2
        while (sample <= MAX_SAMPLE) {
            try {
                val options = BitmapFactory.Options().apply { inSampleSize = sample }
                val decoded = BitmapFactory.decodeFile(file.path, options) ?: return null
                return scale(decoded, edge)
            } catch (e: OutOfMemoryError) {
                AppLogger.warning(TAG, "decode at 1/$sample ran out of memory, trying smaller")
                sample *= 2
            }
        }
        return null
    }

    private fun scale(decoded: Bitmap, edge: Int): Bitmap {
        val ratio = edge.toFloat() / maxOf(decoded.width, decoded.height)
        if (ratio >= 1f) return decoded
        val scaled = Bitmap.createScaledBitmap(
            decoded,
            (decoded.width * ratio).toInt().coerceAtLeast(1),
            (decoded.height * ratio).toInt().coerceAtLeast(1),
            true,
        )
        if (scaled !== decoded) decoded.recycle()
        return scaled
    }

    private fun compress(bitmap: Bitmap, format: Bitmap.CompressFormat, quality: Int): ByteArray =
        ByteArrayOutputStream().also { bitmap.compress(format, quality, it) }.toByteArray()

    private fun read(file: File): ByteArray? = runCatching { file.readBytes() }.getOrNull()

    // 媒体文件名是随机ID且写入后不再改动，文件名即可作为缓存键。
    private fun cached(file: File): InferenceImage? {
        val dir = cacheDir ?: return null
        for ((extension, mime) in CACHE_TYPES) {
            val copy = File(dir, "${file.name}.$extension")
            if (copy.isFile) return read(copy)?.let { InferenceImage(it, mime) }
        }
        return null
    }

    private fun store(file: File, image: InferenceImage) {
        val dir = cacheDir ?: return
        val extension = CACHE_TYPES.first { it.second == image.mimeType }.first
        runCatching {
            dir.mkdirs()
            val temporary = File.createTempFile("inference", ".tmp", dir)
            temporary.writeBytes(image.bytes)
            if (!temporary.renameTo(File(dir, "${file.name}.$extension"))) temporary.delete()
        }
    }

    private companion object {
        private const val TAG = "InferenceImages"
        private const val MAX_SAMPLE = 64
        private val CACHE_TYPES = listOf("jpg" to "image/jpeg", "png" to "image/png")
        private val LADDER = listOf(ImageBudget.MAX_EDGE_PX to 85, 1600 to 75, 1280 to 70, 1024 to 60)
    }
}
