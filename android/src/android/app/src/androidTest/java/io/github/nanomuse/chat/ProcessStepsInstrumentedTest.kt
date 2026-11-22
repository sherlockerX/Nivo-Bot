package io.github.nanomuse.chat

import android.graphics.Rect
import android.os.SystemClock
import android.view.accessibility.AccessibilityNodeInfo
import androidx.activity.compose.setContent
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.openminis.app.MainActivity
import com.openminis.app.ui.chat.AssistantBlock
import com.openminis.app.ui.chat.FlatChatItem
import com.openminis.app.ui.chat.ThinkingBlock
import com.openminis.app.ui.chat.ToolBlockStatus
import com.openminis.app.ui.chat.TypingIndicator
import com.openminis.app.ui.theme.ChatColors
import com.openminis.app.ui.theme.MinisTheme
import io.github.nanomuse.ui.chat.AgentStepPart
import io.github.nanomuse.ui.chat.AgentStepsFold
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/** 过程摘要左对齐、按内容宽度显示，展开后的时间线和思考区在深浅主题与大字号下都可读。 */
@RunWith(AndroidJUnit4::class)
class ProcessStepsInstrumentedTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context get() = instrumentation.targetContext

    private val thinking = AssistantBlock("t1", "thinking", content = "先确认用户要的是左对齐的过程摘要，再看展开后的步骤怎样排列。")
    private val readTool = AssistantBlock("r1", "tool_use", toolStatus = ToolBlockStatus.SUCCESS,
        toolTitle = "Read file", toolName = "file_read", durationMs = 420)
    private val shellTool = AssistantBlock("s1", "tool_use", toolStatus = ToolBlockStatus.RUNNING,
        toolTitle = "Run command", toolName = "shell_execute")
    private val failedTool = AssistantBlock("f1", "tool_use", toolStatus = ToolBlockStatus.FAILED,
        toolTitle = "Open page", toolName = "browser", durationMs = 1200)

    @Test fun should_showLeftAlignedSummaryAndTimeline_inLightTheme() {
        render(dark = false, fontScale = 1f, shot = "process-light") {
            val title = waitForText(label("nm_steps_title_done"))
            val chip = clickable(title)
            val bounds = Rect().also(chip::getBoundsInScreen)
            val metrics = context.resources.displayMetrics
            // 左边线与回答一致（16dp），宽度只到文字结束，不再横跨整行。
            assertTrue("摘要左边缘应在16dp附近：${bounds.left}", bounds.left in (12 * metrics.density).toInt()..(24 * metrics.density).toInt())
            assertTrue("摘要不应占满整行：${bounds.width()} / ${metrics.widthPixels}", bounds.width() < metrics.widthPixels - 48 * metrics.density)
            waitForText(label("nm_steps_title_running"))
            waitForText(label("nm_thinking_title"))
        }
    }

    @Test fun should_stayReadable_inDarkThemeWithLargeText() {
        render(dark = true, fontScale = 1.5f, shot = "process-dark-large") {
            // 大字号下标题和工具数一起换行，完整标题仍可读到。
            waitForText(label("nm_steps_title_done"))
            waitForText(label("nm_steps_title_running"))
        }
    }

    private fun render(dark: Boolean, fontScale: Float, shot: String, checks: () -> Unit) {
        check(context.packageName.endsWith(".uitest"))
        val done = FlatChatItem.AssistantSteps("m1", listOf(thinking, readTool, failedTool), isStreaming = false)
        val running = FlatChatItem.AssistantSteps("m2", listOf(thinking, readTool, shellTool), isStreaming = true)
        val parts = listOf(thinking, readTool, shellTool, failedTool).mapIndexed { index, block ->
            FlatChatItem.AssistantStepPart("m2", block, occurrence = 0, partIndex = 0,
                text = block.content, isStreaming = index == 2, tools = listOf(readTool, shellTool, failedTool))
        }
        ActivityScenario.launch(MainActivity::class.java).use { scenario ->
            scenario.onActivity { activity ->
                activity.setContent {
                    MinisTheme(darkTheme = dark) {
                        CompositionLocalProvider(LocalDensity provides Density(LocalDensity.current.density, fontScale)) {
                            Screen(done, running, parts)
                        }
                    }
                }
            }
            instrumentation.waitForIdleSync()
            SystemClock.sleep(600)
            scenario.onActivity { activity -> screenshot(activity.window.decorView, shot) }
            checks()
        }
    }

    @Composable
    private fun Screen(done: FlatChatItem.AssistantSteps, running: FlatChatItem.AssistantSteps,
        parts: List<FlatChatItem.AssistantStepPart>) {
        // 与聊天列表一致：左右各16dp。
        Column(Modifier.fillMaxSize().background(ChatColors.background).verticalScroll(rememberScrollState())
            .padding(top = 48.dp).padding(horizontal = 16.dp)) {
            TypingIndicator(isVisible = false)
            AgentStepsFold(done, isExpanded = false, isVisible = false, onToggle = {})
            AgentStepsFold(running, isExpanded = false, isVisible = false, onToggle = {})
            // 回答气泡放在摘要下方，截图里可以对照左边线。
            io.github.nanomuse.ui.chat.NmAssistantBubble(enabled = true, rawText = "answer") {
                androidx.compose.material3.Text("这是回答正文，过程摘要与它左对齐。")
            }
            parts.forEachIndexed { index, part ->
                AgentStepPart(part, onDetail = {}, onStop = {}, isFirst = index == 0, isLast = index == parts.lastIndex)
            }
            ThinkingBlock(thinking, isStreaming = false, isVisible = false)
        }
    }

    private fun label(name: String): String {
        val id = context.resources.getIdentifier(name, "string", context.packageName)
        check(id != 0) { "缺少字符串$name" }
        return context.getString(id)
    }

    /** 只截取测试页面自己的窗口，系统弹窗和输入法不会混入截图。 */
    private fun screenshot(view: android.view.View, name: String) {
        val bitmap = android.graphics.Bitmap.createBitmap(view.width, view.height, android.graphics.Bitmap.Config.ARGB_8888)
        view.draw(android.graphics.Canvas(bitmap))
        try {
            java.io.File(context.filesDir, "$name.png").outputStream().use {
                check(bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it))
            }
        } finally { bitmap.recycle() }
    }

    private fun nodes(): List<AccessibilityNodeInfo> {
        val root = instrumentation.uiAutomation.rootInActiveWindow ?: return emptyList()
        val pending = java.util.ArrayDeque<AccessibilityNodeInfo>().apply { add(root) }
        val result = mutableListOf<AccessibilityNodeInfo>()
        while (pending.isNotEmpty()) {
            val node = pending.removeFirst()
            result += node
            for (index in 0 until node.childCount) node.getChild(index)?.let(pending::addLast)
        }
        return result.filter { it.isVisibleToUser }
    }

    private fun waitForText(text: String): AccessibilityNodeInfo {
        val deadline = SystemClock.uptimeMillis() + 10_000
        while (SystemClock.uptimeMillis() < deadline) {
            instrumentation.waitForIdleSync()
            nodes().firstOrNull { it.text?.toString()?.contains(text) == true }?.let { return it }
            SystemClock.sleep(100)
        }
        error("未找到控件$text")
    }

    private fun clickable(initial: AccessibilityNodeInfo): AccessibilityNodeInfo {
        var node: AccessibilityNodeInfo? = initial
        while (node != null && !node.isClickable) node = node.parent
        return checkNotNull(node) { "控件没有可点击父节点" }
    }
}
