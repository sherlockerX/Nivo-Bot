package io.github.nanomuse.ui

import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.width
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.openminis.app.MainActivity
import com.openminis.app.ui.theme.MinisTheme
import io.github.nanomuse.ui.avatar.AgentMood
import io.github.nanomuse.ui.home.MuseHeader
import io.github.nanomuse.ui.muse.MuseTopAppBar
import io.github.nanomuse.ideas.DailyIdea
import io.github.nanomuse.ideas.DailyIdeaCategory
import io.github.nanomuse.ideas.DailyIdeaEdition
import io.github.nanomuse.ideas.DailyIdeaSection
import io.github.nanomuse.ui.ideas.DailyIdeaStripContent
import java.time.LocalDate
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.junit.Assert.assertTrue
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith

/** 在隔离调试应用中测量真实Compose布局，不依赖源码文本断言。 */
@OptIn(ExperimentalMaterial3Api::class)
@RunWith(AndroidJUnit4::class)
class AdaptiveChromeInstrumentedTest {
    /** 冷加载和已加载条带按当前字号占同样高度，素材到达不推动聊天正文。 */
    @Test
    fun should_keepIdeaStripHeight_when_catalogueFinishesLoading() {
        val emptyEdition = DailyIdeaEdition(LocalDate.of(2026, 11, 8), emptyList())
        val loadedEdition = emptyEdition.copy(sections = listOf(DailyIdeaSection(
            DailyIdeaCategory.IDEAS, "点子", listOf(
                DailyIdea("fixture", "💡", "整理今天的想法", "找出下一步可以做的事", "测试提示"),
            ),
        )))
        listOf(1f, 1.3f, 2f).forEach { scale ->
            val measurements = measure(setOf("empty", "loaded")) { bounds, ready ->
                val density = LocalDensity.current.density
                CompositionLocalProvider(LocalDensity provides Density(density, scale)) {
                    Column(Modifier.width(320.dp)) {
                        DailyIdeaStripContent(emptyEdition, {}, {}, recordBounds("empty", bounds, ready))
                        DailyIdeaStripContent(loadedEdition, {}, {}, recordBounds("loaded", bounds, ready))
                    }
                }
            }
            assertEquals("素材加载不能改变条带高度，字号=$scale",
                measurements.getValue("empty").height,
                measurements.getValue("loaded").height, 1f)
        }
    }

    /** 两行名称状态放大后，父标题必须增长而非继续裁切在44dp内。 */
    @Test
    fun should_expandHomeHeader_when_statusUsesLargeFont() {
        val measurements = measure(setOf("normal", "large")) { bounds, ready ->
            val density = LocalDensity.current.density
            Column(Modifier.width(320.dp)) {
                listOf("normal" to 1f, "large" to 2f).forEach { (key, scale) ->
                    CompositionLocalProvider(LocalDensity provides Density(density, scale)) {
                        MuseHeader(
                            mood = AgentMood.ERROR,
                            name = "Muse",
                            statusLine = "等待确认",
                            modifier = recordBounds(key, bounds, ready),
                        )
                    }
                }
            }
        }
        assertTrue(
            "大字号双行名称必须增加标题实际高度",
            measurements.getValue("large").height > measurements.getValue("normal").height,
        )
    }

    /** 大字号双行顶部栏必须容纳完整标题并与两侧操作保持分离。 */
    @Test
    fun should_expandTopBar_when_twoLineTitleUsesLargeFont() {
        val measurements = measure(setOf("normal", "bar", "navigation", "title")) { bounds, ready ->
            val density = LocalDensity.current.density
            Column(Modifier.width(320.dp)) {
                CompositionLocalProvider(LocalDensity provides Density(density, 1f)) {
                    MuseTopAppBar(
                        modifier = recordBounds("normal", bounds, ready),
                        title = { Column { Text("记录"); Text("11月8日", fontSize = 12.sp) } },
                        navigationIcon = { TextButton(onClick = {}) { Text("取消") } },
                        disc = false,
                        windowInsets = WindowInsets(0),
                    )
                }
                CompositionLocalProvider(LocalDensity provides Density(density, 2f)) {
                    MuseTopAppBar(
                        modifier = recordBounds("bar", bounds, ready),
                        navigationIcon = {
                            TextButton(onClick = {}, modifier = recordBounds("navigation", bounds, ready)) {
                                Text("取消")
                            }
                        },
                        title = {
                            Column(recordBounds("title", bounds, ready)) {
                                Text("记录", maxLines = 1)
                                Text("11月8日", fontSize = 12.sp)
                            }
                        },
                        disc = false,
                        windowInsets = WindowInsets(0),
                    )
                }
            }
        }
        val bar = measurements.getValue("bar")
        val title = measurements.getValue("title")
        assertTrue("标题不能超出顶部栏", title.top >= bar.top && title.bottom <= bar.bottom)
        assertTrue("取消按钮不能覆盖标题", measurements.getValue("navigation").right <= title.left)
        assertTrue("大字号双行顶部栏必须增加高度", bar.height > measurements.getValue("normal").height)
    }

    /** 右侧多个操作必须参与标题测量，固定64dp留白不足时也不能重叠。 */
    @Test
    fun should_avoidActions_when_topBarHasMultipleButtons() {
        val measurements = measure(setOf("title", "navigation", "action")) { bounds, ready ->
            Column(Modifier.width(320.dp)) {
                val actions: @Composable RowScope.() -> Unit = {
                    TextButton(onClick = {}, modifier = recordBounds("action", bounds, ready)) { Text("保存") }
                    TextButton(onClick = {}) { Text("更多") }
                }
                MuseTopAppBar(
                    title = { Text("需要完整空间的设置标题", modifier = recordBounds("title", bounds, ready)) },
                    navigationIcon = {
                        TextButton(onClick = {}, modifier = recordBounds("navigation", bounds, ready)) { Text("返回") }
                    },
                    actions = actions,
                    disc = false,
                    windowInsets = WindowInsets(0),
                )
            }
        }
        val title = measurements.getValue("title")
        assertTrue("左侧导航不能覆盖标题", measurements.getValue("navigation").right <= title.left)
        assertTrue("右侧操作不能覆盖标题", title.right <= measurements.getValue("action").left)
    }

    /** 等待指定节点首次完成布局，所有场景仅允许在隔离应用执行。 */
    private fun measure(
        expected: Set<String>,
        content: @Composable (ConcurrentHashMap<String, Rect>, CountDownLatch) -> Unit,
    ): Map<String, Rect> {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        check(context.packageName.endsWith(".uitest")) { "界面测试只能在隔离.uitest应用运行" }
        val bounds = ConcurrentHashMap<String, Rect>()
        val ready = CountDownLatch(expected.size)
        ActivityScenario.launch(MainActivity::class.java).use { scenario ->
            scenario.onActivity { activity ->
                activity.setContent {
                    MinisTheme(darkTheme = false) { content(bounds, ready) }
                }
            }
            assertTrue("布局未在期限内完成", ready.await(10, TimeUnit.SECONDS))
            InstrumentationRegistry.getInstrumentation().waitForIdleSync()
            assertTrue("缺少待测节点", bounds.keys.containsAll(expected))
        }
        return bounds.toMap()
    }

    /** 记录窗口内的实际边界，仅首次布局完成时推进等待器。 */
    private fun recordBounds(
        key: String,
        bounds: ConcurrentHashMap<String, Rect>,
        ready: CountDownLatch,
    ): Modifier = Modifier.onGloballyPositioned { coordinates ->
        if (bounds.put(key, coordinates.boundsInRoot()) == null) ready.countDown()
    }
}
