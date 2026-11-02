package io.github.nanomuse.chat

import android.content.Context
import com.openminis.app.BuildConfig
import com.openminis.app.MinisApp
import com.openminis.app.data.db.MessageEntity
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

/** 仅隔离验收包可调用的合成数据入口，不配置供应商、不发起模型请求。 */
object DebugUiFixture {
    /** 模拟后台时钟，用于验证页面重进而非模型请求。 */
    fun timer(context: Context, params: JSONObject): JSONObject {
        check(BuildConfig.DEBUG && BuildConfig.APPLICATION_ID.endsWith(".uitest"))
        val id = params.getString("session_id")
        if (params.optBoolean("stop")) com.openminis.app.service.SessionActivityTracker.setInactive(id)
        else com.openminis.app.service.SessionActivityTracker.setActive(id, brief = "离线计时验收")
        return JSONObject().put("timing", TurnTimingStore.summary(id))
    }
    /** 创建长历史和十二步工具过程，用于离线交互回归。 */
    suspend fun seed(context: Context, params: JSONObject): JSONObject {
        check(BuildConfig.DEBUG && BuildConfig.APPLICATION_ID.endsWith(".uitest")) { "Fixture is only available in the isolated UI test build" }
        val repo = (context.applicationContext as MinisApp).chatRepository
        val count = params.optInt("count", 400).coerceIn(20, 1200)
        val toolCount = params.optInt("tools", 12).coerceIn(1, 300)
        val reasoningRepeats = params.optInt("reasoning_repeats", 40).coerceIn(1, 2000)
        val session = repo.createSession("offline-fixture", title = "验收对话$count", memoryEnabled = false)
        val start = System.currentTimeMillis() - count * 1000L
        repeat(count) { index ->
            val isUser = index % 2 == 0
            val parts = JSONArray().put(JSONObject().put("type", "text").put("value", if (isUser) "验收问题第${index + 1}条，检查长历史定位。" else "这是第${index + 1}条合成回答，不含真实资料。"))
            if (index == count - 1) repeat(toolCount) { step ->
                parts.put(JSONObject().put("type", "toolUse").put("value", JSONObject()
                    .put("toolUseId", "fixture-$step").put("name", "shell_execute")
                    .put("input", "{\"command\":\"printf test\"}").put("description", "验收步骤${step + 1}")))
            }
            repo.dao.insertMessage(MessageEntity(UUID.randomUUID().toString(), session.id, if (isUser) "user" else "assistant", parts.toString(), start + index * 1000L, sortOrder = index,
                reasoningContent = if (index == count - 1) "这是用于检查折叠位置的合成思考内容。".repeat(reasoningRepeats) else null))
        }
        repo.dao.updateSource(session.id, "ui-test")
        io.github.nanomuse.home.MainChat.set(context, session.id)
        return JSONObject().put("session_id", session.id).put("count", count)
    }
}
