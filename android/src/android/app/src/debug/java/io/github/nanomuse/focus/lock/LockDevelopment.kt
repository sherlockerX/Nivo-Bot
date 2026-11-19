package io.github.nanomuse.focus.lock

/** 紧急退出已接入，开发与正式构建使用相同的24小时上限。 */
internal object LockDevelopment { const val maximumDurationMs = LockRun.MAX_DURATION_MS }
