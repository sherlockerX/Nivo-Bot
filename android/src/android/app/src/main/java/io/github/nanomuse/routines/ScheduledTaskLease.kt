package io.github.nanomuse.routines

/** 在解析会话之前领取整个任务；拒绝重入而不阻塞模型工具的嵌套调用。 */
object ScheduledTaskLease {
    private val active = mutableMapOf<String, Lease>()

    /** 只允许一个持有者，作用域或账号不同也不能同时执行同一任务。 */
    @Synchronized
    fun acquire(taskId: String): Lease? {
        if (active.containsKey(taskId)) return null
        return Lease(taskId).also { active[taskId] = it }
    }

    /** 心跳需要将建会话前的准备阶段同样视为仍在运行。 */
    @Synchronized
    fun isActive(taskId: String): Boolean = active.containsKey(taskId)

    private fun release(lease: Lease) = synchronized(this) {
        if (active[lease.taskId] === lease) active.remove(lease.taskId)
    }

    /** 交接给后台Job后由完成回调释放；重复或迟到释放均安全。 */
    class Lease internal constructor(internal val taskId: String) : AutoCloseable {
        /** 只释放自身领取，不清除后来取得的运行身份。 */
        override fun close() { release(this) }
    }
}
