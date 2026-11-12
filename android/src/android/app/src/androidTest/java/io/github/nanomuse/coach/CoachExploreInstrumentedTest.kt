package io.github.nanomuse.coach

import android.os.Bundle
import android.os.SystemClock
import android.view.accessibility.AccessibilityNodeInfo
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.openminis.app.MainActivity
import com.openminis.app.ui.theme.MinisTheme
import io.github.nanomuse.ui.coach.CoachHeader
import io.github.nanomuse.ui.coach.CoachSceneCard
import io.github.nanomuse.ui.coach.CoachUi
import io.github.nanomuse.ui.coach.coachExploreItems
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/** 场景预览不创建学习档案，真实Compose覆盖导航、大字号与浅深色。 */
@RunWith(AndroidJUnit4::class)
class CoachExploreInstrumentedTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context get() = instrumentation.targetContext
    private val tracks = CoachKind.entries.mapIndexed { index, kind ->
        val titles = listOf("原则与判断", "多视角分析", "英语表达", "表达力", "领导力", "习惯与执行力", "探索自定义能力")
        CoachTrack(CoachCourse("preview-$index", titles[index], "探索空间", kind,
            listOf(CoachUnit("unit", "从一个真实情境开始", "理解方法，再迁移到生活", "讲解与练习", emptyList())), "preview"))
    }
    @Before fun prepare() { check(context.packageName.endsWith(".uitest")); CoachUi.open("city") }

    @Test fun should_renderDistinctScenes_andOpenSelectedCourse() {
        val previous = CoachUi.selectedCourseId.value
        try {
            ActivityScenario.launch(MainActivity::class.java).use { scenario ->
                scenario.onActivity { activity -> activity.setContent {
                    MinisTheme(darkTheme = false) {
                        Column { CoachHeader {}; LazyColumn { coachExploreItems(CoachState(tracks = tracks), tracks.first(), false, {}) } }
                    }
                } }
                waitForText(label("nm_coach_explore_title"))
                screenshot("coach-explore-light")
                tracks.forEach { track ->
                    scenario.onActivity { activity -> activity.setContent {
                        MinisTheme(darkTheme = false) { Column(Modifier.padding(top = 48.dp)) { CoachSceneCard(track) { CoachUi.selectedCourseId.value = track.course.id } } }
                    } }
                    waitForText(track.course.title)
                    screenshot("coach-scene-${track.course.kind.name.lowercase()}")
                    clickText(track.course.title)
                    waitFor { CoachUi.selectedCourseId.value == track.course.id }
                }
            }
        } finally { CoachUi.selectedCourseId.value = previous; CoachUi.open("city") }
    }

    @Test fun should_keepHeaderAndSceneReadable_withDarkThemeAndLargeText() {
        ActivityScenario.launch(MainActivity::class.java).use { scenario ->
            scenario.onActivity { activity -> activity.setContent {
                MinisTheme(darkTheme = true) {
                    CompositionLocalProvider(LocalDensity provides Density(LocalDensity.current.density, 1.5f)) {
                        Column { CoachHeader {}; LazyColumn { coachExploreItems(CoachState(tracks = tracks), tracks.first(), false, {}) } }
                    }
                }
            } }
            waitForText(label("nm_coach_explore_title"))
            screenshot("coach-explore-dark-large")
            clickText(label("nm_coach_explore_more"), allowScroll = true)
            waitForText(label("nm_growth_calendar"))
            waitForText(label("nm_growth_settings_title"))
        }
    }
    private fun label(name: String): String {
        val id = context.resources.getIdentifier(name, "string", context.packageName)
        check(id != 0) { "缺少字符串$name" }
        return context.getString(id)
    }

    /** 截图只留在隔离测试包中，测试数据由当前用例清理。 */
    private fun screenshot(name: String) {
        // 无障碍树可能比绘制早一帧更新，等待渲染落定，避免保存上一个页面。
        instrumentation.waitForIdleSync()
        SystemClock.sleep(500)

        val bitmap = checkNotNull(instrumentation.uiAutomation.takeScreenshot())
        try {
            java.io.File(context.filesDir, "$name.png").outputStream().use {
                check(bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it))
            }
        } finally { bitmap.recycle() }
    }

    private fun nodes(): List<AccessibilityNodeInfo> {
        val root = instrumentation.uiAutomation.rootInActiveWindow ?: return emptyList()
        val pending = java.util.ArrayDeque<AccessibilityNodeInfo>()
        val result = mutableListOf<AccessibilityNodeInfo>()
        pending.add(root)
        while (pending.isNotEmpty()) {
            val node = pending.removeFirst()
            result += node
            for (index in 0 until node.childCount) node.getChild(index)?.let(pending::addLast)
        }
        return result.filter { it.isVisibleToUser }
    }

    private fun findText(text: String): AccessibilityNodeInfo? = nodes().firstOrNull {
        it.text?.toString() == text || it.contentDescription?.toString() == text || it.hintText?.toString() == text
    }

    private fun waitForText(text: String, allowScroll: Boolean = false): AccessibilityNodeInfo {
        var result: AccessibilityNodeInfo? = null
        waitFor {
            result = findText(text)
            if (result == null && allowScroll) nodes().lastOrNull { it.isScrollable && !it.isEditable }
                ?.performAction(AccessibilityNodeInfo.ACTION_SCROLL_FORWARD)
            result != null
        }
        return checkNotNull(result) { "未找到控件$text" }
    }

    private fun clickText(text: String, allowScroll: Boolean = false) = clickNode(waitForText(text, allowScroll))

    private fun clickableNode(initial: AccessibilityNodeInfo?): AccessibilityNodeInfo? {
        var node = initial
        while (node != null && !node.isClickable) node = node.parent
        return node
    }

    private fun clickNode(initial: AccessibilityNodeInfo) {
        val node = checkNotNull(clickableNode(initial)) { "控件没有可点击父节点" }
        assertTrue("点击失败：enabled=${node.isEnabled}, text=${node.text}", node.performAction(AccessibilityNodeInfo.ACTION_CLICK))
        instrumentation.waitForIdleSync()
    }

    private fun setText(node: AccessibilityNodeInfo, value: String) {
        assertTrue(node.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, Bundle().apply {
            putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, value)
        }))
        instrumentation.waitForIdleSync()
    }

    private fun waitFor(predicate: () -> Boolean) {
        val deadline = SystemClock.uptimeMillis() + 10_000
        do {
            instrumentation.waitForIdleSync()
            if (predicate()) return
            SystemClock.sleep(100)
        } while (SystemClock.uptimeMillis() < deadline)
        screenshot("todo-failure")
        java.io.File(context.filesDir, "todo-failure-nodes.txt").writeText(nodes().joinToString("\n") {
            "text=${it.text}; description=${it.contentDescription}; enabled=${it.isEnabled}; scrollable=${it.isScrollable}"
        })
        fail("界面或持久化结果未在10秒内出现")
    }
}
