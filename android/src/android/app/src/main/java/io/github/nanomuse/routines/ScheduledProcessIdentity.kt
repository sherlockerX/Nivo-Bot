package io.github.nanomuse.routines

import java.io.File

/** 从宿主实际进程取得身份，任务上报不信任来宾自行设置的会话变量。 */
object ScheduledProcessIdentity {
    /** 支持公开pid接口与旧Android进程实现，无法取得时保持拒绝上报。 */
    fun pid(process: Process): Int? = runCatching {
        (Process::class.java.getMethod("pid").invoke(process) as Number).toInt()
    }.getOrElse {
        runCatching { process.javaClass.getDeclaredField("pid").apply { isAccessible = true }.getInt(process) }.getOrNull()
    }?.takeIf { it > 0 }

    /** 内核提供的连接对端必须属于已登记的执行进程树。 */
    fun belongsTo(peer: Int, roots: Set<Int>): Boolean {
        var current = peer
        repeat(128) {
            if (current in roots) return true
            if (current <= 1) return false
            current = runCatching { File("/proc/$current/status").useLines { lines ->
                lines.firstOrNull { it.startsWith("PPid:") }?.substringAfter(':')?.trim()?.toIntOrNull()
            } }.getOrNull() ?: return false
        }
        return false
    }
}
