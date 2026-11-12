package io.github.nanomuse.ui.coach

import com.openminis.app.speech.VoiceOutputState
import kotlinx.coroutines.flow.MutableStateFlow

/** 教练页面的临时导航状态，课程与训练数据由命令服务持有。 */
object CoachUi {
    val view = MutableStateFlow("city")
    val selectedCourseId = MutableStateFlow("expression")
    /** 当前可见教练页拥有朗读器，退出后清空。 */
    var readReply: ((String) -> Unit)? = null

    /** 切换视图时停止当前朗读，不改变课程或训练进度。 */
    fun open(view: String) {
        VoiceOutputState.activePlayer?.stop()
        this.view.value = when (view) {
            "map" -> "city"
            "library" -> "courses"
            "train" -> "training"
            "result" -> "results"
            "city", "courses", "training", "results" -> view
            else -> "city"
        }
    }
}
