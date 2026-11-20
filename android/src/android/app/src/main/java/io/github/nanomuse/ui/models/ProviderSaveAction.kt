package io.github.nanomuse.ui.models

import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.openminis.app.R
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** 设置表单共享的保存状态，磁盘写入结束前禁止重复提交，失败时保留原表单。 */
class ProviderSaveAction(
    private val scope: CoroutineScope,
    private val persistenceDispatcher: CoroutineDispatcher = Dispatchers.IO,
) {
    var isSaving by mutableStateOf(false)
        private set
    var hasSaved by mutableStateOf(false)
        private set
    var errorResource by mutableStateOf<Int?>(null)
        private set

    /** 在后台执行同步存储入口，仅成功时返回上一页，不向界面泄漏凭证或异常内容。 */
    fun submit(save: () -> Unit, onSaved: () -> Unit) {
        if (isSaving || hasSaved) return
        isSaving = true
        errorResource = null
        scope.launch {
            try {
                withContext(persistenceDispatcher) { save() }
                // 配置流可能先于或晚于保存回调更新，两种顺序都只允许一次返回。
                hasSaved = true
                onSaved()
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (failure: Exception) {
                errorResource = when (failure.message) {
                    "duplicate_model_id" -> R.string.nm_model_id_conflict
                    "model_changed", "model_no_longer_exists" -> R.string.nm_model_edit_conflict
                    "empty_model_id", "invalid_token_limit" -> R.string.nm_model_form_invalid
                    else -> R.string.nm_provider_save_failed
                }
            } finally {
                isSaving = false
            }
        }
    }

    /** 页面重建后发现该ID已经落盘时只返回一次，不重复提交恢复出的表单。 */
    fun finishRestoredSave(onSaved: () -> Unit) {
        if (isSaving || hasSaved) return
        hasSaved = true
        errorResource = null
        onSaved()
    }

    /** 关闭错误提示，草稿仍由调用表单保留。 */
    fun dismissError() { errorResource = null }
}

/** 将保存生命周期绑定到当前设置页面。 */
@Composable
fun rememberProviderSaveAction(): ProviderSaveAction {
    val scope = rememberCoroutineScope()
    return remember(scope) { ProviderSaveAction(scope) }
}

/** 为所有模型配置表单显示同一套本地化保存错误。 */
@Composable
fun ProviderSaveError(action: ProviderSaveAction) {
    val message = action.errorResource ?: return
    AlertDialog(
        onDismissRequest = action::dismissError,
        text = { Text(stringResource(message)) },
        confirmButton = {
            TextButton(onClick = action::dismissError) { Text(stringResource(R.string.ok)) }
        },
    )
}

/** 在原有保存按钮内显示忙碌状态，保持按钮大小和文字语义。 */
@Composable
fun ProviderSaveProgress(action: ProviderSaveAction) {
    if (!action.isSaving) return
    CircularProgressIndicator(modifier = Modifier.size(18.dp), strokeWidth = 2.dp)
    Spacer(Modifier.width(8.dp))
}
