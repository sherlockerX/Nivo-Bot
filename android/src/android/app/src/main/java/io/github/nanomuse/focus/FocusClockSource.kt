package io.github.nanomuse.focus

import android.content.Context
import android.os.SystemClock

/** 墙钟用于展示日期，单调时钟用于累计，开机编号用于识别重启。 */
internal interface FocusClockSource {
    fun wall(): Long
    fun elapsed(): Long
    fun boot(): Int
}

/** 运行时始终使用设备计时，不允许模型或页面提交时长。 */
internal class DeviceFocusClock(private val context: Context) : FocusClockSource {
    override fun wall(): Long = System.currentTimeMillis()
    override fun elapsed(): Long = SystemClock.elapsedRealtime()
    override fun boot(): Int = FocusStore.boot(context)
}
