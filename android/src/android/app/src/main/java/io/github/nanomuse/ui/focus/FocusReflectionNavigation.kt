package io.github.nanomuse.ui.focus

import android.content.Context
import android.content.Intent
import android.os.Bundle
import com.openminis.app.MainActivity
import io.github.nanomuse.account.AccountData
import io.github.nanomuse.ui.home.HomeBus
import java.util.UUID

/** 显式点击发出的导航凭证；计时与待办内容始终从当前账号数据库读取。 */
data class FocusReflectionRequest(
    val ownerKey: String,
    val ownerEpoch: Long,
    val sessionId: String,
    val requestId: String = UUID.randomUUID().toString(),
)

/** 将独立沉浸窗口交回主导航；Intent消费后移除参数，重建或返回均不重放。 */
object FocusReflectionNavigation {
    private const val EXTRA_OWNER = "nm_reflection_owner"
    private const val EXTRA_EPOCH = "nm_reflection_epoch"
    private const val EXTRA_SESSION = "nm_reflection_session"
    private const val EXTRA_REQUEST = "nm_reflection_request"
    private const val EXTRA_PROCESS = "nm_reflection_process"
    private const val STATE_HANDLED = "nm_reflection_handled"
    private const val STATE_PENDING = "nm_reflection_pending"
    private val processId = UUID.randomUUID().toString()
    private val handledRequests = linkedSetOf<String>()

    /** 仅在用户点击记录心得后启动主界面，不从计时或通知回调自动打开编辑器。 */
    fun openHome(context: Context, request: FocusReflectionRequest) {
        context.startActivity(Intent(context, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            .putExtra(EXTRA_OWNER, request.ownerKey)
            .putExtra(EXTRA_EPOCH, request.ownerEpoch)
            .putExtra(EXTRA_SESSION, request.sessionId)
            .putExtra(EXTRA_REQUEST, request.requestId)
            .putExtra(EXTRA_PROCESS, processId))
    }

    /** 冷启动只沿用持久账号，进程内额外拒绝旧代次以及切出再切回的排队请求。 */
    fun consume(context: Context, intent: Intent?, savedState: Bundle? = null): Boolean {
        savedState?.getStringArrayList(STATE_HANDLED)?.forEach(::rememberHandled)
        val source = intent?.takeIf { it.hasExtra(EXTRA_OWNER) }
            ?: savedState?.getBundle(STATE_PENDING)?.let { Intent().putExtras(it) }
            ?: return false
        val owner = source.getStringExtra(EXTRA_OWNER) ?: return false
        val session = source.getStringExtra(EXTRA_SESSION)
        val requestId = source.getStringExtra(EXTRA_REQUEST)
        val sameProcess = source.getStringExtra(EXTRA_PROCESS) == processId
        val epoch = if (sameProcess) source.getLongExtra(EXTRA_EPOCH, -1) else AccountData.epoch.value
        listOf(EXTRA_OWNER, EXTRA_EPOCH, EXTRA_SESSION, EXTRA_REQUEST, EXTRA_PROCESS).forEach(source::removeExtra)
        if (requestId in handledRequests) return true
        if (owner != AccountData.key(context) || epoch != AccountData.epoch.value ||
            session.isNullOrBlank() || requestId.isNullOrBlank()) return true
        HomeBus.showFocusReflection(FocusReflectionRequest(owner, epoch, session, requestId))
        return true
    }

    /** 导航已消费的凭证随Activity状态保存，系统重建原始Intent时也不会重复进入。 */
    fun rememberHandled(requestId: String) {
        handledRequests.add(requestId)
        while (handledRequests.size > 32) handledRequests.remove(handledRequests.first())
    }

    /** 与主导航保存状态一起记录请求定位，不保存正文或账号凭据。 */
    fun saveState(outState: Bundle) {
        outState.putStringArrayList(STATE_HANDLED, ArrayList(handledRequests))
        HomeBus.focusReflection.value?.let { pending ->
            outState.putBundle(STATE_PENDING, Bundle().apply {
                putString(EXTRA_OWNER, pending.ownerKey)
                putLong(EXTRA_EPOCH, pending.ownerEpoch)
                putString(EXTRA_SESSION, pending.sessionId)
                putString(EXTRA_REQUEST, pending.requestId)
                putString(EXTRA_PROCESS, processId)
            })
        }
    }
}
