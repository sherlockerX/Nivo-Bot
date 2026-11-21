package io.github.nanomuse.chat

import android.animation.ValueAnimator
import android.graphics.Bitmap
import android.graphics.Rect
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.PixelCopy
import android.view.Window
import androidx.activity.compose.setContent
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.boundsInWindow
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.unit.dp
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.openminis.app.MainActivity
import io.github.nanomuse.ui.chat.NivoThinkingStars
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import kotlin.math.roundToInt

/** 从设备截图读取生产组件的真实像素，区分动画、静态图标和空白区域。 */
@RunWith(AndroidJUnit4::class)
class ThinkingStarsInstrumentedTest {
    @Test
    fun should_animateVisibleStarsOnly_when_systemMotionIsEnabled() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        check(instrumentation.targetContext.packageName.endsWith(".uitest"))
        val isVisible = mutableStateOf(true)
        ActivityScenario.launch(MainActivity::class.java).use { scenario ->
            lateinit var window: Window
            lateinit var bounds: Rect
            val ready = CountDownLatch(1)
            scenario.onActivity { activity ->
                window = activity.window
                activity.setContent {
                    Box(Modifier.fillMaxSize().background(Color.Black), contentAlignment = Alignment.Center) {
                        NivoThinkingStars(Color.White, isVisible.value, Modifier.size(48.dp).onGloballyPositioned {
                            val area = it.boundsInWindow()
                            bounds = Rect(area.left.roundToInt(), area.top.roundToInt(), area.right.roundToInt(), area.bottom.roundToInt())
                            ready.countDown()
                        })
                    }
                }
            }
            assertTrue("未排出星形区域", ready.await(10, TimeUnit.SECONDS))
            instrumentation.waitForIdleSync()
            SystemClock.sleep(250)
            val moving = List(5) { SystemClock.sleep(105); frame(window, bounds) }.distinct().size
            if (ValueAnimator.areAnimatorsEnabled()) assertTrue("可见图标需要有不同帧", moving > 1)
            else assertEquals("关闭系统动画时显示静态星形", 1, moving)

            scenario.onActivity { isVisible.value = false }
            instrumentation.waitForIdleSync()
            SystemClock.sleep(200)
            val still = List(3) { SystemClock.sleep(105); frame(window, bounds) }
            assertEquals("切出聊天后画面应稳定", 1, still.distinct().size)
        }
    }

    /** 读取应用实际提交给系统的画面，不会把系统弹窗或导航栏误当成星星。 */
    private fun frame(window: Window, bounds: Rect): Int {
        val image = Bitmap.createBitmap(bounds.width(), bounds.height(), Bitmap.Config.ARGB_8888)
        val copied = CountDownLatch(1)
        val result = AtomicInteger(-1)
        try {
            PixelCopy.request(window, Rect(bounds), image, { code -> result.set(code); copied.countDown() }, Handler(Looper.getMainLooper()))
            assertTrue("未收到窗口画面", copied.await(5, TimeUnit.SECONDS))
            assertEquals(PixelCopy.SUCCESS, result.get())
            val pixels = IntArray(image.width * image.height)
            image.getPixels(pixels, 0, image.width, 0, 0, image.width, image.height)
            val lit = pixels.count { (it and 255) > 48 }
            assertTrue("星形区域不应为空或铺满背景：$lit", lit in 100 until pixels.size / 2)
            // 三个互不连通的亮区中心应同时可见，即使某颗星正处在动画的最低亮度。
            for ((x, y) in listOf(.60f to .61f, .26f to .30f, .74f to .20f)) {
                assertTrue("缺少星形：$x, $y", (image.getPixel((x * image.width).toInt(), (y * image.height).toInt()) and 255) > 100)
            }
            return pixels.contentHashCode()
        } finally {
            image.recycle()
        }
    }
}
