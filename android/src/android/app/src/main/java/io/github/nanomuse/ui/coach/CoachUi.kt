package io.github.nanomuse.ui.coach

import android.content.Context
import com.openminis.app.speech.VoiceOutputState
import io.github.nanomuse.coach.CoachOpenChoice
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow

/** 开始训练时用户在教练页选定的处理方式、时长和今天的需求。 */
data class CoachStartRequest(
    val courseId: String,
    val choice: CoachOpenChoice = CoachOpenChoice.CONTINUE,
    val minutes: Int = CoachUi.DEFAULT_MINUTES,
    val need: String = "",
)

/** 教练页面的临时导航状态，课程与训练数据由命令服务持有。 */
object CoachUi {
    const val DEFAULT_MINUTES = 15
    val view = MutableStateFlow("city")
    val selectedCourseId = MutableStateFlow("expression")
    /** 正在备课的技能ID；为空表示没有备课任务。 */
    val preparing = MutableStateFlow<String?>(null)
    @Volatile var prepJob: Job? = null
    private val pendingStart = MutableStateFlow<CoachStartRequest?>(null)
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

    /** 切换技能只浏览档案，并按账户记住最近一次的选择。 */
    fun select(context: Context, courseId: String) {
        selectedCourseId.value = courseId
        prefs(context).edit().putString(SELECTED_KEY, courseId).apply()
    }

    /** 进入教练页或切换账户时读回这个账户上次浏览的技能。 */
    fun restore(context: Context) {
        prefs(context).getString(SELECTED_KEY, null)?.let { selectedCourseId.value = it }
    }

    /** 记下这次开始的选项，由首页在打开训练时取走。 */
    fun requestStart(request: CoachStartRequest) { pendingStart.value = request }

    /** 取走与该技能匹配的开始选项；没有时按默认值续上已有课节。 */
    fun takeStart(courseId: String): CoachStartRequest {
        val request = pendingStart.value?.takeIf { it.courseId == courseId } ?: CoachStartRequest(courseId)
        pendingStart.value = null
        return request
    }

    /** 取消备课；已保存的档案和历史不受影响。 */
    fun cancelPreparing() { prepJob?.cancel() }

    private fun prefs(context: Context) = context.applicationContext.getSharedPreferences(
        "coach-ui-${io.github.nanomuse.account.AccountData.key(context.applicationContext).hashCode()}", 0)

    private const val SELECTED_KEY = "selected_course"
}
