package io.github.nanomuse.ui.chat

import android.content.SharedPreferences
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.runtime.*
import androidx.compose.ui.platform.LocalContext
import com.openminis.app.ui.chat.FlatChatItem
import io.github.nanomuse.chat.FoldViewportAnchor

/** 折叠选择与待应用的视口锚点，点击和下一次测量之间不绘制过渡位置。 */
@Stable
internal class AgentStepsState(private val preferences: SharedPreferences) {
    var expanded by mutableStateOf(preferences.all.filterValues { it == true }.keys.toSet())
        private set
    private var pending: Pair<String, Int>? = null

    /** 只记录标题的逻辑位置，正文交给外层列表按需构建。 */
    fun toggle(row: FlatChatItem.AssistantSteps, listState: LazyListState) {
        pending = listState.layoutInfo.visibleItemsInfo.firstOrNull { it.key == row.key }
            ?.let { row.key to it.offset }
        val isExpanded = row.messageId !in expanded
        expanded = if (isExpanded) expanded + row.messageId else expanded - row.messageId
        preferences.edit().putBoolean(row.messageId, isExpanded).apply()
    }

    /** 在同次重组的提交阶段定位，不启动跨帧滚动协程。 */
    fun applyAnchor(listState: LazyListState, rows: List<FlatChatItem>, extraItems: Int) {
        val anchor = pending ?: return
        pending = null
        val request = FoldViewportAnchor.requestFor(anchor.first, rows.asReversed().map { it.key }, extraItems, anchor.second)
            ?: return
        listState.requestScrollToItem(request.index, request.scrollOffset)
    }
}

/** 会话切换时重新读取已保存的折叠选择。 */
@Composable
internal fun rememberAgentStepsState(sessionId: String): AgentStepsState {
    val context = LocalContext.current.applicationContext
    return remember(context, sessionId) {
        AgentStepsState(context.getSharedPreferences("nm_step_folds", android.content.Context.MODE_PRIVATE))
    }
}
