package io.github.nanomuse.ui.focus

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.background
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.Alignment
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.openminis.app.R
import kotlinx.coroutines.flow.MutableStateFlow

/** 专注内部页面由右上工具入口切换，待办入口只传任务ID。 */
object FocusUi {
    val view=MutableStateFlow("timer")
    val exportRequested=MutableStateFlow(false)
    val taskId=MutableStateFlow<String?>(null)
    fun openTask(id:String) { taskId.value=id;view.value="timer" }
}

/** 与待办、教练共用紧凑页头，不新增底部导航按钮。 */
@Composable
fun FocusHeader(onOpenDrawer:()->Unit) {
    val view by FocusUi.view.collectAsState()
    Row(Modifier.fillMaxWidth().background(com.openminis.app.ui.theme.ChatColors.background).statusBarsPadding()
        .padding(horizontal=12.dp,vertical=10.dp).heightIn(min=56.dp),verticalAlignment=Alignment.CenterVertically) {
        IconButton(onClick={if(view=="timer") onOpenDrawer() else FocusUi.view.value="timer"}) {
            Icon(if(view=="timer") Icons.Outlined.Menu else Icons.AutoMirrored.Outlined.ArrowBack,stringResource(if(view=="timer") R.string.nm_focus_menu else R.string.nm_focus_back))
        }
        Text(stringResource(when(view){"history"->R.string.nm_focus_history;"stats"->R.string.nm_focus_stats;else->R.string.nm_focus_title}),
            Modifier.weight(1f),style=MaterialTheme.typography.titleLarge,fontWeight=FontWeight.SemiBold)
        IconButton(onClick={FocusUi.view.value="history"}) { Icon(Icons.Outlined.History,stringResource(R.string.nm_focus_history)) }
        IconButton(onClick={FocusUi.view.value="stats"}) { Icon(Icons.Outlined.BarChart,stringResource(R.string.nm_focus_stats)) }
        IconButton(onClick={FocusUi.exportRequested.value=true}) { Icon(Icons.Outlined.FileDownload,stringResource(R.string.nm_focus_export)) }
    }
}
