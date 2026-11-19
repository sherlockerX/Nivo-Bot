package io.github.nanomuse.focus.lock

/** 固定诊断代号不能携带页面文字或异常详情。 */
enum class LockDiagnosticAction { START, COMPLETE, EMERGENCY, BLOCK, RETURN, RETURN_FAILED, PERMISSIONS_MISSING, SERVICE_LOST, RESTORE, SCHEDULE_WAIT, WINDOW_BLOCK, PANEL_CLOSE }

/** 一项脱离页面内容的元数据记录。 */
data class LockDiagnosticEntry(val wall: Long, val elapsed: Long, val action: LockDiagnosticAction,
    val packageName: String? = null, val windowType: Int? = null, val count: Int = 1)

/** 有界诊断队列。 */
class LockDiagnosticBuffer {
    private val rows = java.util.ArrayDeque<LockDiagnosticEntry>()
    private val packagePattern = Regex("[A-Za-z][A-Za-z0-9_]*(\\.[A-Za-z0-9_]+)*")
    /** 追加一项固定元数据。 */
    @Synchronized
    fun append(entry: LockDiagnosticEntry) {
        val safe = entry.copy(packageName = entry.packageName?.takeIf {
            it.length <= 255 && packagePattern.matches(it)
        })
        val old = rows.peekLast()
        val isDuplicate = old != null && old.action == safe.action && old.packageName == safe.packageName &&
            old.windowType == safe.windowType && safe.elapsed - old.elapsed in 0..2000
        if (isDuplicate && old != null) {
            rows.removeLast()
            rows.addLast(safe.copy(count = (old.count.toLong() + safe.count).coerceAtMost(Int.MAX_VALUE.toLong()).toInt()))
        } else rows.addLast(safe)
        while (rows.size > 400) rows.removeFirst()
    }
    /** 读取不可变快照。 */
    @Synchronized
    fun entries(): List<LockDiagnosticEntry> = rows.toList()
    /** 删除内存中的诊断。 */
    @Synchronized
    fun clear() { rows.clear() }
}
