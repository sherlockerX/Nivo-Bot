package io.github.nanomuse.coach

/** 文件迁移前撤销旧服务，在迁移完成前阻止重新打开固定路径。 */
class CoachSpaceGate<T>(private val invalidate: (T) -> Unit) {
    private var instance: T? = null
    private var instanceKey: String? = null
    private var isChanging = false

    /** 缓存只在完整可用的账号空间内创建。 */
    @Synchronized fun get(key: String = "", factory: () -> T): T {
        check(!isChanging) { "Coach space is changing; reopen the current page" }
        if (instanceKey != key) reset()
        return instance ?: factory().also { instance = it; instanceKey = key }
    }

    /** 等待已有同步写入结束后撤销引用，后续旧命令只会失败。 */
    @Synchronized fun begin() {
        isChanging = true
        reset()
    }

    /** 目录和身份全部恢复后才允许新服务读取。 */
    @Synchronized fun finish() { isChanging = false }

    /** 重读服务不会意外解除正在进行的账号迁移。 */
    @Synchronized fun reset() { instance?.let(invalidate); instance = null; instanceKey = null }
}
