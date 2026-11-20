package io.github.nanomuse.ui.coach

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.filled.Menu
import androidx.compose.material.icons.outlined.CalendarMonth
import androidx.compose.material.icons.outlined.Settings
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.openminis.app.R
import com.openminis.app.speech.VoiceOutputState
import io.github.nanomuse.ui.feed.FeedUi

/**
 * 教练页的标题栏。技能列表上是抽屉、标题和两个入口（训练日历、教练设置），
 * 不超过紧凑屏幕建议的三个操作；技能档案、课程库和设置等子页显示返回箭头和页标题。
 */
@Composable
fun CoachHeader(onOpenDrawer: () -> Unit) {
    val current by CoachUi.view.collectAsState()
    val skillTitle by CoachUi.skillTitle.collectAsState()
    val isHome = current == "city"
    Row(Modifier.fillMaxWidth().background(com.openminis.app.ui.theme.ChatColors.background).statusBarsPadding()
        .padding(horizontal = 8.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
        if (isHome) {
            IconButton(onClick = onOpenDrawer) { Icon(Icons.Default.Menu, stringResource(R.string.nm_open_drawer)) }
        } else {
            IconButton(onClick = { VoiceOutputState.activePlayer?.stop(); CoachUi.open("city") }) {
                Icon(Icons.AutoMirrored.Outlined.ArrowBack, stringResource(R.string.nm_coach_home_back))
            }
        }
        val title = when (current) {
            "skill" -> skillTitle.ifBlank { stringResource(R.string.nm_coach_home_skill) }
            "courses" -> stringResource(R.string.nm_coach_home_library)
            "settings" -> stringResource(R.string.nm_coach_settings_title)
            else -> stringResource(R.string.nm_coach_title)
        }
        Text(title, fontWeight = FontWeight.Bold,
            style = if (isHome) MaterialTheme.typography.headlineSmall else MaterialTheme.typography.titleLarge,
            maxLines = 1, overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f).padding(horizontal = 4.dp).semantics { heading() })
        if (isHome) {
            CoachHeaderButton(Icons.Outlined.CalendarMonth, stringResource(R.string.nm_growth_calendar)) {
                FeedUi.calendarOpen.value = true
            }
            CoachHeaderButton(Icons.Outlined.Settings, stringResource(R.string.nm_coach_settings_title)) {
                CoachUi.open("settings")
            }
        }
    }
}

/** 每个图标至少48dp，并保留可访问名称。 */
@Composable
private fun CoachHeaderButton(icon: ImageVector, label: String, onClick: () -> Unit) {
    Surface(onClick = { VoiceOutputState.activePlayer?.stop(); onClick() }, shape = RoundedCornerShape(50),
        color = Color.Transparent, modifier = Modifier.size(48.dp)) {
        Box(contentAlignment = Alignment.Center) { Icon(icon, contentDescription = label, modifier = Modifier.size(22.dp)) }
    }
}
