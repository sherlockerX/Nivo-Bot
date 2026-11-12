package io.github.nanomuse.media

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.async
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.*
import org.junit.Test

/** 资源在准备失败、取消和宿主关闭时只释放一次。 */
@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
class PreparedResourceTest {
    private class Resource { var releases = 0 }

    @Test fun should_releaseOnSetupFailure() = runTest {
        val resource = Resource()
        try {
            awaitPreparedResource({ resource }, { it.releases++ }) { _, _, _ -> error("broken") }
            fail("必须传递准备失败")
        } catch (failure: IllegalStateException) { assertEquals("broken", failure.message) }
        assertEquals(1, resource.releases)
    }

    @Test fun should_releaseOnAsyncFailure() = runTest {
        val resource = Resource()
        try {
            awaitPreparedResource({ resource }, { it.releases++ }) { _, _, failure ->
                failure(IllegalArgumentException("unsupported"))
            }
            fail("必须传递异步失败")
        } catch (failure: IllegalArgumentException) { assertEquals("unsupported", failure.message) }
        assertEquals(1, resource.releases)
    }

    @Test fun should_ignoreLateSuccessAndReleaseOnce_when_cancelledDuringPreparation() = runTest {
        val resource = Resource()
        var complete: (() -> Unit)? = null
        val result = async { awaitPreparedResource({ resource }, { it.releases++ }) { _, ready, _ -> complete = ready } }
        runCurrent()
        result.cancel()
        runCurrent()
        complete!!()
        assertTrue(result.isCancelled)
        assertEquals(1, resource.releases)
    }

    @Test fun should_releaseExactlyOnce_when_ownerClosesReadyResource() = runTest {
        val resource = Resource()
        val owned = awaitPreparedResource({ resource }, { it.releases++ }) { _, ready, _ -> ready() }
        assertSame(resource, owned.value)
        assertEquals(0, resource.releases)
        owned.close(); owned.close()
        assertEquals(1, resource.releases)
    }

    @Test fun should_preserveCancellationException_fromSetup() = runTest {
        val resource = Resource()
        val expected = CancellationException("left screen")
        try {
            awaitPreparedResource({ resource }, { it.releases++ }) { _, _, _ -> throw expected }
            fail("取消不能吞掉")
        } catch (failure: CancellationException) {
            assertEquals(expected.message, failure.message)
            // 开启调用栈恢复时协程复制异常，并以原异常为cause；两种模式均须保留取消来源。
            assertTrue(failure === expected || failure.cause === expected)
        }
        assertEquals(1, resource.releases)
    }

    @Test fun should_release_when_cancelledAfterCallbackBeforeDelivery() = runTest {
        val resource = Resource()
        var complete: (() -> Unit)? = null
        val result = async { awaitPreparedResource({ resource }, { it.releases++ }) { _, ready, _ -> complete = ready } }
        runCurrent()
        complete!!()
        result.cancel()
        runCurrent()
        assertEquals(1, resource.releases)
    }
}
