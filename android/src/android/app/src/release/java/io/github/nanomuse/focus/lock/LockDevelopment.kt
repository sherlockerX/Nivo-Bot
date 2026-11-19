package io.github.nanomuse.focus.lock

/** 正式构建只保留产品规定的24小时上限，不包含调试结束入口。 */
internal object LockDevelopment { const val maximumDurationMs = LockRun.MAX_DURATION_MS }
