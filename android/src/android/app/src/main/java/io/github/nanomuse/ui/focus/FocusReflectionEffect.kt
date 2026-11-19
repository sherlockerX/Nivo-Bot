package io.github.nanomuse.ui.focus

import android.widget.Toast
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.platform.LocalContext
import androidx.lifecycle.Lifecycle
import androidx.navigation.NavHostController
import com.openminis.app.R
import io.github.nanomuse.account.AccountData
import io.github.nanomuse.focus.FocusBackdropStore
import io.github.nanomuse.focus.FocusReflectionDrafts
import io.github.nanomuse.focus.FocusStore
import io.github.nanomuse.mosaic.MosaicStore
import io.github.nanomuse.todo.TodoStore
import io.github.nanomuse.ui.home.HomeBus
import io.github.nanomuse.ui.home.HomeShell
import io.github.nanomuse.ui.home.HomeTab
import io.github.nanomuse.ui.mosaic.MosaicEditSource
import io.github.nanomuse.ui.mosaic.MosaicUi
import io.github.nanomuse.ui.mosaic.mosaicEditRoute
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.flatMapLatest

/** 主导航统一消费专注心得点击，窗口重建保留待处理请求，成功后立即清除。 */
@Composable
fun FocusReflectionEffect(navController: NavHostController) {
    val context = LocalContext.current
    val request by HomeBus.focusReflection.collectAsState()
    val accountEpoch by AccountData.epoch.collectAsState()
    LaunchedEffect(request, accountEpoch) {
        val pending = request ?: return@LaunchedEffect
        var isHandled = false
        try {
            if (pending.ownerKey != AccountData.key(context) || pending.ownerEpoch != AccountData.epoch.value) {
                isHandled = true
                return@LaunchedEffect
            }
            awaitResumedEntry(navController)
            val focus = FocusStore.get(context)
            check(focus.ownerKey == pending.ownerKey && focus.ownerEpoch == pending.ownerEpoch)
            val draft = FocusReflectionDrafts.open(focus, TodoStore.get(context), MosaicStore.get(context), pending.sessionId)
            FocusBackdropStore(context, focus.ownerKey, focus.ownerEpoch).rememberImmersive(null)
            awaitResumedEntry(navController)
            if (pending.ownerKey != AccountData.key(context) || pending.ownerEpoch != AccountData.epoch.value) {
                isHandled = true
                return@LaunchedEffect
            }
            HomeBus.showTab(HomeTab.MOSAIC)
            MosaicUi.showDay.value = draft.day
            if (!HomeShell.active) {
                // 宽屏主界面没有标签消费者，先放入碎片页面，编辑器关闭时才能回到记录。
                HomeShell.openTab(navController, HomeTab.MOSAIC)
                awaitResumedEntry(navController)
                check(pending.ownerKey == AccountData.key(context) && pending.ownerEpoch == AccountData.epoch.value)
            }
            navController.navigate(mosaicEditRoute(draft.day, source = MosaicEditSource.TEXT, draftId = draft.id)) {
                launchSingleTop = true
            }
            isHandled = true
        } catch (cancelled: CancellationException) {
            // 账号迁移使凭证失效；窗口重建的取消则交给新导航继续消费。
            isHandled = pending.ownerEpoch != AccountData.epoch.value || pending.ownerKey != AccountData.key(context)
            throw cancelled
        } catch (_: Exception) {
            isHandled = true
            Toast.makeText(context, R.string.nm_focus_error, Toast.LENGTH_SHORT).show()
        } finally {
            if (isHandled) {
                FocusReflectionNavigation.rememberHandled(pending.requestId)
                HomeBus.handledFocusReflection(pending)
            }
        }
    }
}

/** 等当前页面可交互后导航，避免冷启动或从沉浸窗口返回时丢弃点击。 */
@OptIn(ExperimentalCoroutinesApi::class)
private suspend fun awaitResumedEntry(navController: NavHostController) {
    navController.currentBackStackEntryFlow.flatMapLatest { it.lifecycle.currentStateFlow }
        .first { it.isAtLeast(Lifecycle.State.RESUMED) }
}
