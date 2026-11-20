package io.github.nanomuse.models

import java.util.concurrent.CancellationException

/** 数据库提交是保存边界，旧版JSON镜像通过持久标记在失败或中断后补写。 */
internal object ProviderMirrorSync {
    const val META_KEY = "nm_json_mirror_sync"
    const val PENDING_VALUE = "pending-v1"
    const val SYNCED_VALUE = "synced-v1"

    /** 同步结果只说明镜像状态，PENDING仍代表数据库已经成功提交。 */
    enum class Result { SYNCED, PENDING }

    /** 空配置只要有同步元数据，就与尚未初始化的数据库区分开。 */
    fun hasDatabaseSnapshot(instanceCount: Int, hasMarker: Boolean, hasSyncHash: Boolean): Boolean =
        instanceCount > 0 || hasMarker || hasSyncHash

    /** 已知DB更新较新时禁止回退旧镜像；其他情况保留原来的降级导入规则。 */
    fun shouldUseDatabase(
        isDatabaseReadable: Boolean,
        isPending: Boolean,
        storedHash: String?,
        mirrorHash: String?,
    ): Boolean {
        check(!isPending || isDatabaseReadable) { "provider_pending_database_unreadable" }
        return isDatabaseReadable && (isPending || storedHash == mirrorHash)
    }

    /** 写入回调必须在同一DB事务中保存配置及待同步标记，DB失败直接向上报告。 */
    suspend fun persist(
        writeDatabase: suspend () -> Unit,
        writeMirror: () -> Boolean,
        markMirrorSynced: suspend () -> Unit,
    ): Result {
        writeDatabase()
        return synchronize(writeMirror, markMirrorSynced)
    }

    /** 镜像或确认失败时保留待同步标记，取消仍传播给调用方。 */
    suspend fun synchronize(
        writeMirror: () -> Boolean,
        markMirrorSynced: suspend () -> Unit,
    ): Result = try {
        if (writeMirror()) {
            markMirrorSynced()
            Result.SYNCED
        } else Result.PENDING
    } catch (cancelled: CancellationException) {
        throw cancelled
    } catch (_: Exception) {
        Result.PENDING
    }
}
