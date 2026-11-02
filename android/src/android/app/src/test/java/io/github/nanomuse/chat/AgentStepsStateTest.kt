package io.github.nanomuse.chat

import android.content.SharedPreferences
import androidx.compose.foundation.lazy.LazyListItemInfo
import androidx.compose.foundation.lazy.LazyListLayoutInfo
import androidx.compose.foundation.lazy.LazyListState
import com.openminis.app.ui.chat.AssistantBlock
import com.openminis.app.ui.chat.FlatChatItem
import io.github.nanomuse.ui.chat.AgentStepsState
import org.junit.Assert.*
import org.junit.Test
import org.mockito.Mockito.*

/** 点击只产生一次同帧定位请求，快速开合不残留延迟滚动任务。 */
class AgentStepsStateTest {
    private val preferences = mock(SharedPreferences::class.java)
    private val editor = mock(SharedPreferences.Editor::class.java)
    private val listState = mock(LazyListState::class.java)
    private val layout = mock(LazyListLayoutInfo::class.java)
    private val item = mock(LazyListItemInfo::class.java)
    private val row = FlatChatItem.AssistantSteps("answer", listOf(AssistantBlock("tool", "tool_use")), false)

    private fun state(saved: Map<String, Boolean> = emptyMap()): AgentStepsState {
        `when`(preferences.all).thenReturn(saved)
        `when`(preferences.edit()).thenReturn(editor)
        `when`(editor.putBoolean(anyString(), anyBoolean())).thenReturn(editor)
        `when`(listState.layoutInfo).thenReturn(layout)
        `when`(layout.visibleItemsInfo).thenReturn(listOf(item))
        `when`(item.key).thenReturn(row.key)
        `when`(item.offset).thenReturn(425)
        return AgentStepsState(preferences)
    }

    @Test fun should_restoreSelection_when_reenteringChat() {
        assertEquals(setOf("answer"), state(mapOf("answer" to true, "old" to false)).expanded)
    }

    @Test fun should_requestOnlyFinalPosition_when_applyingExpandedRows() {
        val state = state()
        state.toggle(row, listState)
        val rows = expandAgentStepRows(listOf(row, FlatChatItem.AssistantHeader("reply")), state.expanded)
        state.applyAnchor(listState, rows, 2)
        state.applyAnchor(listState, rows, 2)
        verify(listState, times(1)).requestScrollToItem(4, -425)
        verify(editor).putBoolean("answer", true)
        verify(editor).apply()
    }

    @Test fun should_discardIntermediateExpansion_when_toggledTwiceBeforeLayout() {
        val state = state()
        state.toggle(row, listState)
        state.toggle(row, listState)
        state.applyAnchor(listState, expandAgentStepRows(listOf(row), state.expanded), 0)
        assertTrue(state.expanded.isEmpty())
        verify(listState).requestScrollToItem(0, -425)
    }
}
