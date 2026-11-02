package io.github.nanomuse.sandbox

import android.content.Context
import java.io.File

/** 为升级后的镜像补齐跨会话持久目录，不移动或删除旧工作区。 */
object SharedHome {
    /** 幂等创建挂载点、脚本和运行日志目录。 */
    fun prepare(context: Context, rootfs: File?) {
        rootfs?.let { File(it, "var/minis/home").mkdirs() }
        val home = File(context.filesDir, "minis-global/home")
        listOf("bin", "state", "logs").forEach { File(home, it).mkdirs() }
        val readme = File(home, "README.md")
        if (!readme.exists()) readme.writeText("""
            # 持久工作区
            此目录跨会话共享。稳定脚本放在/var/minis/home/bin，状态放在state，运行日志放在logs。
            /var/minis/workspace、attachments、offloads和browser仍属于当前会话。归档不代表自动删除。
            旧的/var/minis/shared继续有效。切换账户时此目录随账户隔离。
        """.trimIndent())
    }
}
