package io.github.nanomuse.chat

import android.os.Build

/** 系统禁止后台启动时返回明确失败，其他编程错误继续传播。 */
fun tryForegroundStart(start: () -> Unit, onRejected: (IllegalStateException) -> Unit): Boolean {
    return try {
        start()
        true
    } catch (failure: IllegalStateException) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S ||
            failure !is android.app.ServiceStartNotAllowedException) throw failure
        onRejected(failure)
        false
    }
}
