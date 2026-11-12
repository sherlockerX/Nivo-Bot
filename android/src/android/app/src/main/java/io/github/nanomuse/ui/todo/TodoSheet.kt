package io.github.nanomuse.ui.todo

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import io.github.nanomuse.ui.home.MuseTones

/** 统一底部详情面板：操作固定、内容滚动，键盘出现时保留可见操作区。 */
@Composable
internal fun TodoSheet(onDismissRequest: () -> Unit, title: @Composable () -> Unit,
    text: @Composable () -> Unit, confirmButton: @Composable () -> Unit,
    dismissButton: @Composable () -> Unit) {
    Dialog(onDismissRequest = onDismissRequest,
        properties = DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false)) {
        Box(Modifier.fillMaxSize().statusBarsPadding().navigationBarsPadding().imePadding(), contentAlignment = Alignment.BottomCenter) {
            Surface(Modifier.widthIn(max = 640.dp).fillMaxWidth().fillMaxHeight(.94f),
                shape = RoundedCornerShape(topStart = 30.dp, topEnd = 30.dp), color = MuseTones.canvas) {
                Column {
                    Box(Modifier.fillMaxWidth().padding(top = 10.dp, bottom = 18.dp), contentAlignment = Alignment.Center) {
                        Surface(Modifier.width(36.dp).height(4.dp), color = MuseTones.hairline, shape = RoundedCornerShape(2.dp)) {}
                    }
                    Box(Modifier.fillMaxWidth().padding(horizontal = 24.dp, vertical = 8.dp)) {
                        ProvideTextStyle(MaterialTheme.typography.headlineSmall) { title() }
                    }
                    Column(Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(horizontal = 20.dp, vertical = 18.dp)) { text() }
                    HorizontalDivider(color = MuseTones.hairline)
                    Row(Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 12.dp),
                        horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
                        dismissButton()
                        confirmButton()
                    }
                }
            }
        }
    }
}
