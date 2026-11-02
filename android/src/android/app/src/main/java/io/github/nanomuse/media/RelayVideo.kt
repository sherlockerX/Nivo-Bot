package io.github.nanomuse.media

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Rect
import android.util.Base64
import com.openminis.app.logging.AppLogger
import kotlinx.coroutines.delay
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.MultipartBody
import okhttp3.Request
import okhttp3.RequestBody
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject

/**
 * Mosaic: clips through a relay of one's own (new-api, one-api and their kin), which put Veo,
 * Grok Imagine, Seedance, Kling, Hailuo and other video models behind one key. Two APIs are
 * spoken, chosen per provider on its page ([Api]):
 *
 *  - new-api's own: `POST {base}/video/generations` with the model, the words, the first frame as
 *    a data URL and the length returns a task; `GET {base}/video/generations/{task_id}` is polled.
 *  - OpenAI's: `POST {base}/videos` as a form with the first frame as `input_reference`;
 *    `GET {base}/videos/{id}` is polled and the file comes from `GET {base}/videos/{id}/content`.
 *
 * *Automatic* tries new-api's first and falls back to OpenAI's when the relay does not have it.
 * Statuses come in the relay's own words or the upstream's (`succeeded`, `completed`,
 * `SUCCESS`), so both are read; a task that succeeds without a URL is fetched from `/content`.
 */
object RelayVideo {
    private const val TAG = "RelayVideo"
    private val DONE = setOf("succeeded", "success", "completed", "complete", "done", "finished")
    private val FAILED = setOf("failed", "failure", "fail", "error", "cancelled", "canceled", "expired")

    /** Which video API a relay speaks; stored per provider by [MediaModels.setVideoApi]. */
    enum class Api(val id: String) {
        AUTO("auto"),
        NEW_API("newapi"),
        OPENAI("openai");

        companion object {
            fun byId(id: String?): Api = entries.firstOrNull { it.id == id } ?: AUTO
        }
    }

    /** The relay answered 404 or 405: it does not have this API. */
    private class NotThere : Exception()

    suspend fun generate(
        ep: VideoGen.Endpoint,
        prompt: String,
        frame: Bitmap?,
        seconds: Int,
        ratio: String?,
        onProgress: (VideoGen.Progress) -> Unit,
    ): ByteArray {
        val base = ep.apiBase
        if (ep.relayApi != Api.OPENAI) {
            try {
                return newApi(ep, base, prompt, frame, seconds, ratio, onProgress)
            } catch (e: NotThere) {
                if (ep.relayApi == Api.NEW_API) throw VideoGen.VideoGenException("This relay has no video API at $base/video/generations")
            }
        }
        return try {
            openAi(ep, base, prompt, frame, seconds, ratio, onProgress)
        } catch (e: NotThere) {
            throw VideoGen.VideoGenException("This relay has no video API at $base/video/generations or $base/videos")
        }
    }

    // ── new-api ───────────────────────────────────────────────────────────

    private suspend fun newApi(
        ep: VideoGen.Endpoint, base: String, prompt: String, frame: Bitmap?, seconds: Int, ratio: String?,
        onProgress: (VideoGen.Progress) -> Unit,
    ): ByteArray {
        val created = submit(ep, "$base/video/generations", body(ep.model, prompt, frame, seconds, ratio).toString().toRequestBody(JSON))
        val taskId = taskId(created) ?: throw VideoGen.VideoGenException(created.optString("message").ifBlank { "No task id" })
        onProgress(VideoGen.Progress.Submitted)
        val task = poll(ep, "$base/video/generations/$taskId", onProgress)
        onProgress(VideoGen.Progress.Downloading)
        return url(task)?.let(VideoGen::download) ?: content(ep, base, taskId)
    }

    internal fun body(model: String, prompt: String, frame: Bitmap?, seconds: Int, ratio: String?): JSONObject {
        val body = JSONObject().put("model", model).put("prompt", prompt).put("duration", seconds(model, seconds))
        frame?.let {
            body.put("image", "data:image/png;base64," + Base64.encodeToString(VideoGen.pngBytes(it), Base64.NO_WRAP))
        }
        // A picture sets the frame's shape; words alone ask for one.
        if (frame == null && ratio != null) {
            val (w, h) = size(ratio)
            body.put("width", w).put("height", h).put("metadata", JSONObject().put("aspect_ratio", ratio))
        }
        return body
    }

    // ── OpenAI ────────────────────────────────────────────────────────────

    private suspend fun openAi(
        ep: VideoGen.Endpoint, base: String, prompt: String, frame: Bitmap?, seconds: Int, ratio: String?,
        onProgress: (VideoGen.Progress) -> Unit,
    ): ByteArray {
        val form = MultipartBody.Builder().setType(MultipartBody.FORM)
            .addFormDataPart("model", ep.model)
            .addFormDataPart("prompt", prompt)
            .addFormDataPart("seconds", seconds(ep.model, seconds).toString())
        if (frame != null) {
            // The reference has to be the clip's size; a white margin disappears into the avatar's white ground.
            form.addFormDataPart("size", "${WIDE.first}x${WIDE.second}")
            form.addFormDataPart("input_reference", "first-frame.png", VideoGen.pngBytes(widen(frame)).toRequestBody("image/png".toMediaType()))
        } else if (ratio != null) {
            val (w, h) = size(ratio)
            form.addFormDataPart("size", "${w}x$h")
        }
        val created = submit(ep, "$base/videos", form.build())
        val id = taskId(created) ?: throw VideoGen.VideoGenException(created.optString("message").ifBlank { "No video id" })
        onProgress(VideoGen.Progress.Submitted)
        val task = poll(ep, "$base/videos/$id", onProgress)
        onProgress(VideoGen.Progress.Downloading)
        return url(task)?.let(VideoGen::download) ?: content(ep, base, id)
    }

    private val WIDE = 1280 to 720

    /** [frame] centred on a white 16:9 canvas of [WIDE]'s size. */
    private fun widen(frame: Bitmap): Bitmap {
        val (w, h) = WIDE
        val out = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(out)
        canvas.drawColor(Color.WHITE)
        val scale = minOf(w.toFloat() / frame.width, h.toFloat() / frame.height)
        val dw = (frame.width * scale).toInt()
        val dh = (frame.height * scale).toInt()
        canvas.drawBitmap(frame, null, Rect((w - dw) / 2, (h - dh) / 2, (w + dw) / 2, (h + dh) / 2), null)
        return out
    }

    // ── shared ────────────────────────────────────────────────────────────

    /** The length each family takes nearest to [seconds]: they accept a few fixed values, not any number. */
    internal fun seconds(model: String, seconds: Int): Int {
        val m = model.lowercase()
        return when {
            "veo" in m -> when { seconds <= 4 -> 4; seconds <= 6 -> 6; else -> 8 }
            "sora" in m -> when { seconds <= 4 -> 4; seconds <= 8 -> 8; else -> 12 }
            "kling" in m -> if (seconds <= 5) 5 else 10
            "hailuo" in m || "minimax" in m -> if (seconds <= 6) 6 else 10
            "seedance" in m || "wan" in m -> seconds.coerceIn(5, 10)
            "vidu" in m -> if (seconds <= 4) 4 else 8
            else -> seconds
        }
    }

    private fun size(ratio: String): Pair<Int, Int> = when (ratio) {
        "16:9" -> 1280 to 720
        "9:16" -> 720 to 1280
        "4:3" -> 960 to 720
        "3:4" -> 720 to 960
        "21:9" -> 1680 to 720
        else -> 960 to 960
    }

    private fun submit(ep: VideoGen.Endpoint, url: String, body: RequestBody): JSONObject {
        val req = Request.Builder()
            .url(url)
            .header("Authorization", "Bearer ${ep.apiKey}")
            .post(body)
            .build()
        return VideoGen.http.newCall(req).execute().use { resp ->
            val text = resp.body?.string().orEmpty()
            if (resp.code == 404 || resp.code == 405) throw NotThere()
            if (!resp.isSuccessful) {
                AppLogger.warning(TAG, "submit $url HTTP ${resp.code}: ${text.take(300)}")
                throw VideoGen.VideoGenException("HTTP ${resp.code}" + message(text))
            }
            runCatching { JSONObject(text) }.getOrElse { throw VideoGen.VideoGenException("Unreadable response") }
        }
    }

    /** Polls [url] until the task is over; returns the finished task, or throws with the task's reason. */
    private suspend fun poll(ep: VideoGen.Endpoint, url: String, onProgress: (VideoGen.Progress) -> Unit): JSONObject {
        val started = System.currentTimeMillis()
        while (true) {
            delay(VideoGen.POLL_MS)
            val req = Request.Builder()
                .url(url)
                .header("Authorization", "Bearer ${ep.apiKey}")
                .get()
                .build()
            val json = VideoGen.http.newCall(req).execute().use { resp ->
                val text = resp.body?.string().orEmpty()
                if (!resp.isSuccessful) throw VideoGen.VideoGenException("Task query failed (HTTP ${resp.code})" + message(text))
                runCatching { JSONObject(text) }.getOrElse { throw VideoGen.VideoGenException("Unreadable task") }
            }
            val task = json.optJSONObject("data")?.takeIf { it.has("status") } ?: json
            val status = task.optString("status").lowercase()
            when {
                status in DONE -> return if (url(task) != null) task else json
                status in FAILED -> throw VideoGen.VideoGenException(failure(task))
            }
            val elapsed = ((System.currentTimeMillis() - started) / 1000).toInt()
            onProgress(VideoGen.Progress.Running(elapsed))
            if (System.currentTimeMillis() - started > VideoGen.MAX_WAIT_MS) throw VideoGen.VideoGenException("Timed out after ${elapsed / 60} min")
        }
    }

    /** The OpenAI-shaped download, for a relay that keeps the file and names no URL. */
    private fun content(ep: VideoGen.Endpoint, base: String, id: String): ByteArray {
        val req = Request.Builder()
            .url("$base/videos/$id/content")
            .header("Authorization", "Bearer ${ep.apiKey}")
            .get()
            .build()
        return VideoGen.http.newCall(req).execute().use { resp ->
            if (!resp.isSuccessful) throw VideoGen.VideoGenException("No video URL (HTTP ${resp.code})")
            resp.body?.bytes()?.takeIf { it.isNotEmpty() } ?: throw VideoGen.VideoGenException("Empty video")
        }
    }

    internal fun taskId(json: JSONObject): String? =
        json.optString("task_id").ifBlank { json.optString("id") }.ifBlank {
            json.optJSONObject("data")?.let { it.optString("task_id").ifBlank { it.optString("id") } }
                ?: json.optString("data")
        }.takeIf { it.isNotBlank() }

    /** Where relays and their upstreams put the file: at the top, in `metadata`, `content`, `output` or a result list. */
    internal fun url(task: JSONObject): String? {
        fun JSONObject.first(vararg keys: String): String? = keys.firstNotNullOfOrNull { k -> optString(k).takeIf { it.startsWith("http") } }
        return task.first("url", "video_url", "result_url")
            ?: task.optJSONObject("metadata")?.first("url", "video_url")
            ?: task.optJSONObject("content")?.first("video_url", "url")
            ?: task.optJSONObject("output")?.first("video_url", "url")
            ?: (task.optJSONArray("video_result") ?: task.optJSONArray("videos"))?.let(::firstUrl)
    }

    private fun firstUrl(list: JSONArray): String? =
        (0 until list.length()).firstNotNullOfOrNull { i -> list.optJSONObject(i)?.optString("url")?.takeIf { it.startsWith("http") } }

    private fun failure(task: JSONObject): String {
        val error = task.opt("error")
        val reason = when (error) {
            is JSONObject -> error.optString("message").ifBlank { error.optString("code") }
            is String -> error
            else -> ""
        }.ifBlank { task.optString("fail_reason") }.ifBlank { task.optString("message") }
        return reason.ifBlank { "Video task ${task.optString("status").ifBlank { "failed" }}" }
    }

    private fun message(text: String): String =
        runCatching {
            val json = JSONObject(text)
            json.optJSONObject("error")?.optString("message").orEmpty().ifBlank { json.optString("message") }
        }.getOrNull()?.takeIf { it.isNotBlank() }?.let { ": $it" } ?: ""

    private val JSON = "application/json".toMediaType()
}
