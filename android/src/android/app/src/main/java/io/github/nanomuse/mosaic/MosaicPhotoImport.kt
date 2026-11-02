package io.github.nanomuse.mosaic

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Matrix
import android.net.Uri
import androidx.exifinterface.media.ExifInterface
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import java.io.IOException
import java.util.UUID
import kotlin.math.max

/**
 * Turns a picked or captured picture into the draft's own copy: upright, at most [LONG_EDGE] on
 * its long side, opaque, re-encoded as JPEG (which drops the EXIF block, GPS included). The
 * picker's URI is read once here and never kept: a year later it may point at nothing.
 */
object MosaicPhotoImport {
    // Large enough that a photographed page of homework or notes stays legible when zoomed in.
    const val LONG_EDGE = 2560
    private const val QUALITY = 85

    class Staged(val path: String, val width: Int, val height: Int)

    /** The picture could not be decoded (damaged, an unsupported format, or a cloud item that is offline). */
    class UnreadableException : IOException("unreadable picture")

    suspend fun stage(context: Context, uri: Uri, draftsDir: File): Staged = withContext(Dispatchers.IO) {
        val resolver = context.contentResolver
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        // A bounds-only decode always returns null; the sizes land in `bounds`.
        (resolver.openInputStream(uri) ?: throw UnreadableException()).use { BitmapFactory.decodeStream(it, null, bounds) }
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) throw UnreadableException()

        // Decode at the largest power-of-two step that still leaves the long edge at LONG_EDGE or more.
        var sample = 1
        while (max(bounds.outWidth, bounds.outHeight) / (sample * 2) >= LONG_EDGE) sample *= 2
        val decoded = resolver.openInputStream(uri)?.use {
            BitmapFactory.decodeStream(it, null, BitmapFactory.Options().apply { inSampleSize = sample })
        } ?: throw UnreadableException()

        val orientation = runCatching {
            resolver.openInputStream(uri)?.use {
                ExifInterface(it).getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)
            }
        }.getOrNull() ?: ExifInterface.ORIENTATION_NORMAL

        val upright = transform(decoded, orientation)
        val opaque = if (upright.hasAlpha()) onWhite(upright) else upright
        try {
            draftsDir.mkdirs()
            val id = UUID.randomUUID().toString()
            val tmp = File(draftsDir, "$id.tmp")
            val out = File(draftsDir, "$id.jpg")
            tmp.outputStream().use { stream ->
                if (!opaque.compress(Bitmap.CompressFormat.JPEG, QUALITY, stream)) throw IOException("encode failed")
                stream.fd.sync()
            }
            if (!tmp.renameTo(out)) {
                tmp.delete()
                throw IOException("rename failed")
            }
            Staged(out.absolutePath, opaque.width, opaque.height)
        } finally {
            opaque.recycle()
        }
    }

    /** Rotates and mirrors per the EXIF orientation and scales down to [LONG_EDGE] in one pass. */
    private fun transform(source: Bitmap, orientation: Int): Bitmap {
        val matrix = Matrix()
        when (orientation) {
            ExifInterface.ORIENTATION_ROTATE_90 -> matrix.postRotate(90f)
            ExifInterface.ORIENTATION_ROTATE_180 -> matrix.postRotate(180f)
            ExifInterface.ORIENTATION_ROTATE_270 -> matrix.postRotate(270f)
            ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> matrix.postScale(-1f, 1f)
            ExifInterface.ORIENTATION_FLIP_VERTICAL -> matrix.postScale(1f, -1f)
            ExifInterface.ORIENTATION_TRANSPOSE -> { matrix.postRotate(90f); matrix.postScale(-1f, 1f) }
            ExifInterface.ORIENTATION_TRANSVERSE -> { matrix.postRotate(-90f); matrix.postScale(-1f, 1f) }
        }
        val longEdge = max(source.width, source.height)
        if (longEdge > LONG_EDGE) {
            val s = LONG_EDGE.toFloat() / longEdge
            matrix.postScale(s, s)
        }
        if (matrix.isIdentity) return source
        val result = Bitmap.createBitmap(source, 0, 0, source.width, source.height, matrix, true)
        if (result !== source) source.recycle()
        return result
    }

    /** A transparent picture on white, since JPEG has no alpha and black would show through. */
    private fun onWhite(source: Bitmap): Bitmap {
        val result = Bitmap.createBitmap(source.width, source.height, Bitmap.Config.ARGB_8888)
        Canvas(result).apply {
            drawColor(Color.WHITE)
            drawBitmap(source, 0f, 0f, null)
        }
        source.recycle()
        return result
    }
}
