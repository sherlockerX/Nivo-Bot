package io.github.nanomuse.chat

import android.app.ForegroundServiceStartNotAllowedException
import android.os.Build
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

/** 使用设备真实框架异常验证拒绝处理，不启动后台服务或修改应用数据。 */
@RunWith(AndroidJUnit4::class)
class ForegroundStartGuardInstrumentedTest {
    @Test fun should_returnFalse_when_systemRejectsForegroundStart() {
        assumeTrue(Build.VERSION.SDK_INT >= 31)
        var rejected = false
        val allowed = tryForegroundStart(
            start = { throw ForegroundServiceStartNotAllowedException("fixture boot restriction") },
            onRejected = { rejected = true },
        )
        assertFalse(allowed)
        assertTrue(rejected)
    }

    @Test fun should_preserveUnknownFailure_andAllowSuccessfulStart() {
        assertTrue(tryForegroundStart({}, { fail("成功启动不能报告失败") }))
        val original = IllegalStateException("fixture programming failure")
        try {
            tryForegroundStart({ throw original }, { fail("未知错误不能吞掉") })
            fail("必须传播未知错误")
        } catch (failure: IllegalStateException) {
            assertSame(original, failure)
        }
    }
}
