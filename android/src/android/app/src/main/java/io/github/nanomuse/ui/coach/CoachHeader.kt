package io.github.nanomuse.ui.coach

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Menu
import androidx.compose.material.icons.automirrored.outlined.MenuBook
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.openminis.app.R
import com.openminis.app.speech.VoiceOutputState
import io.github.nanomuse.ui.feed.FeedUi
import io.github.nanomuse.ui.home.MuseTones

/** 页标题与紧凑右上入口沿用主App层级，大字号时操作条可横向滚动。 */
@Composable
fun CoachHeader(onOpenDrawer: () -> Unit) {
    val current by CoachUi.view.collectAsState()
    var showMore by remember { mutableStateOf(false) }
    Row(Modifier.fillMaxWidth().background(com.openminis.app.ui.theme.ChatColors.background).statusBarsPadding()
        .padding(horizontal = 12.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
        IconButton(onClick = onOpenDrawer) { Icon(Icons.Default.Menu, stringResource(R.string.nm_open_drawer)) }
        Text(stringResource(R.string.nm_coach_title), fontWeight = FontWeight.Bold, style = MaterialTheme.typography.headlineSmall,
            modifier = Modifier.weight(1f).heightIn(min = 48.dp).clickable(role = Role.Button) {
                VoiceOutputState.activePlayer?.stop(); CoachUi.open("city")
            }.padding(vertical = 10.dp))
        Row(Modifier.widthIn(max = 192.dp).horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(2.dp)) {
            CoachHeaderButton(Icons.Outlined.EmojiEvents, stringResource(R.string.nm_coach_results), current == "results") { CoachUi.open("results") }
            CoachHeaderButton(Icons.Outlined.Forum, stringResource(R.string.nm_coach_chat_records), current == "training") { CoachUi.open("training") }
            CoachHeaderButton(Icons.AutoMirrored.Outlined.MenuBook, stringResource(R.string.nm_coach_courses), current == "courses") { CoachUi.open("courses") }
            Box {
                CoachHeaderButton(Icons.Outlined.MoreHoriz, stringResource(R.string.nm_coach_explore_more), showMore) { showMore = true }
                DropdownMenu(expanded = showMore, onDismissRequest = { showMore = false }, containerColor = MuseTones.surface, shape = RoundedCornerShape(20.dp)) {
                    DropdownMenuItem(text = { Text(stringResource(R.string.nm_growth_calendar)) }, leadingIcon = { Icon(Icons.Outlined.CalendarMonth, null) },
                        onClick = { showMore = false; FeedUi.calendarOpen.value = true })
                    DropdownMenuItem(text = { Text(stringResource(R.string.nm_growth_settings_title)) }, leadingIcon = { Icon(Icons.Outlined.Tune, null) },
                        onClick = { showMore = false; FeedUi.settingsOpen.value = true })
                }
            }
        }
    }
}

/** 每个图标至少48dp，选中态和可访问名称均保留。 */
@Composable
private fun CoachHeaderButton(icon: ImageVector, label: String, isSelected: Boolean, onClick: () -> Unit) {
    Surface(onClick = { VoiceOutputState.activePlayer?.stop(); onClick() }, shape = RoundedCornerShape(50),
        color = if (isSelected) MuseTones.fill else androidx.compose.ui.graphics.Color.Transparent,
        modifier = Modifier.size(48.dp).semantics { selected = isSelected }) {
        Box(contentAlignment = Alignment.Center) { Icon(icon, contentDescription = label, modifier = Modifier.size(22.dp)) }
    }
}
