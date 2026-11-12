package io.github.nanomuse.coach

import android.content.Context
import io.github.nanomuse.growth.GrowthStore
import java.io.File

/** 使用App现有本地空间；不经云同步，不把聊天删除映射为课程删除。 */
object CoachRuntime {
    private val space = CoachSpaceGate<CoachCommandService> { it.invalidate() }
    val epoch = kotlinx.coroutines.flow.MutableStateFlow(0L)

    /** 账户空间切换后丢弃内存引用，下一次重新读取当前空间文件。 */
    @Synchronized
    fun reset() { space.reset(); epoch.value += 1 }

    /** 文件移动前使全部旧引用失效，并禁止迁移中重新创建服务。 */
    @Synchronized fun beginTransition() { space.begin(); epoch.value += 1 }

    /** 当前账号目录完全就绪后通知界面重新载入。 */
    @Synchronized fun finishTransition() { space.finish(); epoch.value += 1 }

    /** 页面和模型工具获得同一实例，初始化只读取旧记录。 */
    @Synchronized
    fun service(context: Context): CoachCommandService {
        val root = File(context.filesDir, "minis-global/nanomuse/growth/coach-v2")
        return space.get(root.canonicalPath) {
            val legacy = GrowthStore.state.value.tracks
            CoachCommandService(CoachFileStore(root), CoachCurriculumRepository.load(context),
                legacyPaused = legacy.filter { it.status == GrowthStore.PAUSED }.map { it.id }.toSet(),
                legacyNotes = legacy.associate { it.id to "旧课程与评分保留在日历；新单元从起点验证，不从旧等级推断掌握。" })
        }
    }
}
