package io.github.nanomuse.chat

import android.app.Activity
import android.os.SystemClock
import android.view.View
import com.openminis.app.BuildConfig
import org.json.JSONArray
import org.json.JSONObject

/** 仅隔离验收包记录实际绘制帧中的折叠标题位置，不采集聊天正文。 */
object DebugFoldTrace {
    private val isAllowed = BuildConfig.DEBUG && BuildConfig.APPLICATION_ID.endsWith(".uitest")
    private var root: View? = null
    private var target: String? = null
    private val positions = mutableMapOf<String, Pair<Any, Float>>()
    private val traces = mutableListOf<JSONObject>()
    private var frames: JSONArray? = null
    private var startedAt = 0L
    /** 在Compose列表绘制完成后采样，避免平台绘制前回调先于延迟布局执行。 */
    fun drawnFrame() {
        if (!isAllowed || root == null) return
        val destination = frames
        if (destination != null && destination.length() < 180) {
            destination.put(JSONObject()
                .put("ms", (SystemClock.elapsedRealtimeNanos() - startedAt) / 1_000_000.0)
                .put("y", positions[target]?.second ?: JSONObject.NULL))
        }
    }

    /** 在主线程挂接或读取绘制探针；普通包和正式包均拒绝调用。 */
    fun command(activity: Activity?, action: String): JSONObject {
        check(isAllowed) { "Fold tracing requires the isolated UI test build" }
        if (action == "start") {
            detach()
            traces.clear()
            frames = null
            target = null
            root = checkNotNull(activity).window.decorView
        }
        if (action == "stop") detach()
        return JSONObject().put("traces", JSONArray(traces))
    }

    /** 更新布局后的坐标，实际采样由绘制回调完成。 */
    fun placed(key: String, y: Float, owner: Any) {
        if (isAllowed) positions[key] = owner to y
    }

    /** 离开可见布局后清除旧坐标，防止将消失的标题误判为位置稳定。 */
    fun removed(key: String, owner: Any) {
        if (isAllowed && positions[key]?.first === owner) positions.remove(key)
    }

    /** 每次点击单独记录，便于发现最终位置正确但中间帧跳动的问题。 */
    fun toggled(key: String) {
        if (!isAllowed || root == null) return
        target = key
        startedAt = SystemClock.elapsedRealtimeNanos()
        frames = JSONArray()
        traces.add(JSONObject().put("key", key).put("beforeY", positions[key]?.second).put("frames", frames))
        root?.invalidate()
    }

    private fun detach() {
        root = null
    }
}
