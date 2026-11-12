package io.github.nanomuse.chat

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.AnnotatedString
import java.util.concurrent.Executors
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test
import org.mockito.Mockito.mockStatic
import org.mockito.Mockito.mock
import android.os.Looper

/** 直接验证真实Markdown缓存的配色隔离和快照持有，不模拟解析器。 */
class MarkdownPresentationCacheTest {
    private val cacheClass = Class.forName("com.openminis.app.ui.chat.MarkdownParseCaches")
    private val colorsClass = Class.forName("com.openminis.app.ui.chat.MdColors")
    private val blockClass = Class.forName("com.openminis.app.ui.chat.MdBlock")
    private val cache = cacheClass.getDeclaredField("INSTANCE").apply { isAccessible = true }.get(null)

    private fun colors(color: Color): Any = colorsClass.declaredConstructors
        .first { it.parameterCount == 10 }.apply { isAccessible = true }
        .newInstance(*Array<Any>(10) { color.value.toLong() })

    private fun invoke(name: String, block: Any, palette: Any): Any? = cacheClass
        .getDeclaredMethod(name, blockClass, colorsClass).apply { isAccessible = true }
        .invoke(cache, block, palette)

    @Suppress("UNCHECKED_CAST")
    private fun texts(snapshot: Any): Map<String, AnnotatedString> = snapshot.javaClass
        .getDeclaredField("text").apply { isAccessible = true }.get(snapshot) as Map<String, AnnotatedString>

    @Test fun should_keepNewPaletteAndSnapshot_when_inlineCacheIsEvicted() = runBlocking {
        val raw = "[fixture](https://example.invalid)"
        val block = Class.forName("com.openminis.app.ui.chat.MdBlock\$Paragraph")
            .getDeclaredConstructor(String::class.java).apply { isAccessible = true }.newInstance(raw)
        val red = colors(Color.Red)
        val blue = colors(Color.Blue)
        Executors.newSingleThreadExecutor().asCoroutineDispatcher().use { worker ->
            val first = preparePresentation(raw to "red", worker) { withAndroidDiagnostics { invoke("presentation", block, red)!! } }
            assertNotNull(invoke("cachedPresentation", block, red))
            assertNull(invoke("cachedPresentation", block, blue))
            val second = preparePresentation(raw to "blue", worker) { withAndroidDiagnostics { invoke("presentation", block, blue)!! } }
            assertTrue(texts(first.value).getValue(raw).spanStyles.any { it.item.color == Color.Red })
            assertTrue(texts(second.value).getValue(raw).spanStyles.any { it.item.color == Color.Blue })
            val lru = cacheClass.getDeclaredField("inlineLru").apply { isAccessible = true }.get(null)
            (lru as MutableMap<*, *>).clear()
            assertTrue(texts(second.value).getValue(raw).spanStyles.any { it.item.color == Color.Blue })
            assertNull(second.forKey(raw to "red"))
        }
    }

    @Test fun should_prepareEmptyCells_when_tableRowsHaveDifferentWidths() = runBlocking {
        val table = Class.forName("com.openminis.app.ui.chat.MdBlock\$Table")
            .getDeclaredConstructor(String::class.java, List::class.java, List::class.java)
            .apply { isAccessible = true }.newInstance("table", listOf("a", "b"), listOf(listOf("only")))
        val snapshot = preparePresentation("table") { withAndroidDiagnostics { invoke("presentation", table, colors(Color.Blue))!! } }
        assertEquals("", texts(snapshot.value).getValue("").text)
        assertEquals("only", texts(snapshot.value).getValue("only").text)
    }

    @Test fun should_publishIncrementalResultBeforeRender_when_liveTailGrows() = runBlocking {
        val raw = (1..90).joinToString("\n") { "正文和`code`组成可复用的闭合前缀$it" } + "\n" + "tail".repeat(100)
        val block = Class.forName("com.openminis.app.ui.chat.MdBlock\$Paragraph")
            .getDeclaredConstructor(String::class.java).apply { isAccessible = true }.newInstance(raw)
        val palette = colors(Color.Blue)
        preparePresentation("live") {
            withAndroidDiagnostics {
                cacheClass.getDeclaredMethod("prewarmLiveTail", List::class.java, colorsClass)
                    .apply { isAccessible = true }.invoke(cache, listOf(block), palette)
            }
        }
        val snapshot = invoke("cachedPresentation", block, palette)
        assertNotNull(snapshot)
        val inline = cacheClass.getDeclaredField("inlineLru").apply { isAccessible = true }
            .get(null) as Map<*, *>
        assertSame(inline[raw to palette], texts(snapshot!!).getValue(raw))
        assertTrue(texts(snapshot).getValue(raw).text.contains("可复用的闭合前缀"))
    }

    /** 仅替代Android日志环境，实际结构和内联解析均执行生产代码。 */
    private fun <T> withAndroidDiagnostics(block: () -> T): T = mockStatic(Looper::class.java).use { looper ->
        looper.`when`<Looper> { Looper.getMainLooper() }.thenReturn(mock(Looper::class.java))
        mockStatic(android.util.Log::class.java).use { block() }
    }
}
