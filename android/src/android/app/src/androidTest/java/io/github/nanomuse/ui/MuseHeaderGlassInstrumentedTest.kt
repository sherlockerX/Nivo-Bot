package io.github.nanomuse.ui

import android.graphics.Bitmap
import android.os.Handler
import android.os.Looper
import android.view.PixelCopy
import androidx.activity.compose.setContent
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.boundsInWindow
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.sp
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.filters.SdkSuppress
import androidx.test.platform.app.InstrumentationRegistry
import com.openminis.app.MainActivity
import com.openminis.app.ui.theme.ChatColors
import com.openminis.app.ui.theme.MinisTheme
import dev.chrisbanes.haze.hazeSource
import dev.chrisbanes.haze.rememberHazeState
import io.github.nanomuse.ui.home.MuseHeaderGlass
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.floor
import kotlin.math.roundToInt
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/** 只用合成图案与PixelCopy验证真实Haze；不读取用户消息或照片。 */
@RunWith(AndroidJUnit4::class)
@SdkSuppress(minSdkVersion = 31)
class MuseHeaderGlassInstrumentedTest {
    /** 浅色磨砂必须保留背景对比，前景文字不参与模糊。 */
    @Test
    fun should_blurSourceAndKeepTitleSharp_when_lightTheme() {
        verifyTheme(isDark = false)
    }

    /** 深色与不可见回退均不能把标题下的消息源覆盖成纯色。 */
    @Test
    fun should_blurSourceAndKeepTitleSharp_when_darkTheme() {
        verifyTheme(isDark = true)
    }

    private fun verifyTheme(isDark: Boolean) {
        val blurred = capture(isDark, isVisible = true)
        val fallback = capture(isDark, isVisible = false)
        try {
            listOf("磨砂" to blurred, "不可见回退" to fallback).forEach { (mode, scene) ->
                val stripe = stripeProfile(scene)
                assertTrue("${mode}不能覆盖成纯色，dark=$isDark", stripe.max() - stripe.min() > 45.0)
                assertTrue("${mode}前景文字必须保留清晰边缘，dark=$isDark", titleEdge(scene) > 90)
            }
            val blurredEdge = maximumStep(stripeProfile(blurred))
            val fallbackEdge = maximumStep(stripeProfile(fallback))
            assertTrue("回退应保留未模糊条纹边缘", fallbackEdge > 100.0)
            assertTrue(
                "API31+应实际模糊源边缘：blur=$blurredEdge fallback=$fallbackEdge dark=$isDark",
                blurredEdge < fallbackEdge * 0.85,
            )
        } finally {
            blurred.bitmap.recycle()
            fallback.bitmap.recycle()
        }
    }

    /** 左侧纯色承载前景文字，右侧黑白条纹和文字属于唯一hazeSource。 */
    @Composable
    private fun Fixture(
        isDark: Boolean,
        isVisible: Boolean,
        bounds: ConcurrentHashMap<String, Rect>,
        ready: CountDownLatch,
    ) {
        val state = rememberHazeState()
        val background = ChatColors.background
        val foreground = if (isDark) Color.White else Color.Black
        Box(Modifier.fillMaxSize().background(background)) {
            Box(Modifier.size(280.dp, 112.dp).record("scene", bounds, ready)) {
                Box(Modifier.fillMaxSize().hazeSource(state)) {
                    Canvas(Modifier.fillMaxSize()) {
                        drawRect(background)
                        repeat(5) { index ->
                            drawRect(
                                color = if (index % 2 == 0) Color.Black else Color.White,
                                topLeft = Offset((128 + index * 32).dp.toPx(), 0f),
                                size = Size(32.dp.toPx(), size.height),
                            )
                        }
                    }
                    Text("SOURCE", color = Color.Black, fontSize = 16.sp,
                        modifier = Modifier.offset(140.dp, 72.dp))
                }
                MuseHeaderGlass(state, Modifier.fillMaxSize(), isVisible)
                Text(
                    "HIII", color = foreground, fontSize = 28.sp,
                    fontFamily = FontFamily.Monospace, fontWeight = FontWeight.Bold,
                    modifier = Modifier.offset(12.dp, 12.dp).record("title", bounds, ready),
                )
            }
        }
    }

    /** 等待真实布局及多帧合成后复制窗口像素，不能用软件draw冒充RenderEffect。 */
    private fun capture(isDark: Boolean, isVisible: Boolean): Scene {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        check(instrumentation.targetContext.packageName.endsWith(".uitest"))
        val bounds = ConcurrentHashMap<String, Rect>()
        val ready = CountDownLatch(2)
        lateinit var result: Scene
        ActivityScenario.launch(MainActivity::class.java).use { scenario ->
            scenario.onActivity { activity ->
                activity.setContent {
                    val density = LocalDensity.current.density
                    CompositionLocalProvider(LocalDensity provides Density(density, fontScale = 1f)) {
                        MinisTheme(darkTheme = isDark) { Fixture(isDark, isVisible, bounds, ready) }
                    }
                }
            }
            assertTrue("合成界面未完成布局", ready.await(10, TimeUnit.SECONDS))
            val rendered = CountDownLatch(1)
            scenario.onActivity { activity ->
                val view = activity.window.decorView
                var remainingFrames = 8
                val frame = object : Runnable {
                    override fun run() {
                        if (--remainingFrames == 0) rendered.countDown() else {
                            view.invalidate()
                            view.postOnAnimation(this)
                        }
                    }
                }
                view.postOnAnimation(frame)
            }
            assertTrue("Haze未完成合成帧", rendered.await(10, TimeUnit.SECONDS))
            instrumentation.waitForIdleSync()
            val scene = bounds.getValue("scene")
            val region = android.graphics.Rect(floor(scene.left).toInt(), floor(scene.top).toInt(),
                ceil(scene.right).toInt(), ceil(scene.bottom).toInt())
            val bitmap = Bitmap.createBitmap(region.width(), region.height(), Bitmap.Config.ARGB_8888)
            val copied = CountDownLatch(1)
            val status = AtomicInteger(-1)
            scenario.onActivity { activity ->
                PixelCopy.request(activity.window, region, bitmap, { code ->
                    status.set(code)
                    copied.countDown()
                }, Handler(Looper.getMainLooper()))
            }
            assertTrue("PixelCopy未返回", copied.await(10, TimeUnit.SECONDS))
            assertEquals("必须读取实际窗口像素", PixelCopy.SUCCESS, status.get())
            val title = bounds.getValue("title").translate(-region.left.toFloat(), -region.top.toFloat())
            result = Scene(bitmap, title, scene.width / 280f)
        }
        return result
    }

    /** 远离前景和源文字，在固定条纹边界周围按多行均值抑制Haze噪声。 */
    private fun stripeProfile(scene: Scene): List<Double> {
        val top = (20 * scene.pixelsPerDp).roundToInt()
        val bottom = (28 * scene.pixelsPerDp).roundToInt()
        val left = (140 * scene.pixelsPerDp).roundToInt()
        val right = (180 * scene.pixelsPerDp).roundToInt()
        return (left..right).map { x ->
            (top..bottom).map { y -> luminance(scene.bitmap.getPixel(x, y)) }.average()
        }
    }

    /** 粗体竖笔画应有陡峭边缘；若前景被4dp模糊，此像素跃迁会显著下降。 */
    private fun titleEdge(scene: Scene): Int {
        val box = scene.title
        var maximum = 0
        for (y in ceil(box.top).toInt() until floor(box.bottom).toInt()) {
            for (x in ceil(box.left).toInt() until floor(box.right).toInt() - 1) {
                maximum = maxOf(maximum, abs(luminance(scene.bitmap.getPixel(x + 1, y)) -
                    luminance(scene.bitmap.getPixel(x, y))))
            }
        }
        return maximum
    }

    private fun maximumStep(profile: List<Double>): Double =
        profile.zipWithNext { left, right -> abs(left - right) }.max()

    private fun luminance(pixel: Int): Int =
        (android.graphics.Color.red(pixel) * 299 + android.graphics.Color.green(pixel) * 587 +
            android.graphics.Color.blue(pixel) * 114) / 1000

    private fun Modifier.record(
        key: String, bounds: ConcurrentHashMap<String, Rect>, ready: CountDownLatch,
    ): Modifier = onGloballyPositioned { coordinates ->
        if (bounds.put(key, coordinates.boundsInWindow()) == null) ready.countDown()
    }

    /** 截图及其前景边界只在本次断言期间存活。 */
    private data class Scene(val bitmap: Bitmap, val title: Rect, val pixelsPerDp: Float)
}
