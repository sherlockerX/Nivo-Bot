package io.github.nanomuse.ui.coach

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowForward
import androidx.compose.material.icons.outlined.Add
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.openminis.app.R
import io.github.nanomuse.coach.CoachCourse
import io.github.nanomuse.coach.CoachKind
import io.github.nanomuse.coach.CoachState
import io.github.nanomuse.coach.CoachTrack
import io.github.nanomuse.ui.home.MuseTones

/** 场景卡使用稳定课程ID逐项惰性展示，课程增加时不一次布局整座地图。 */
@OptIn(ExperimentalLayoutApi::class)
internal fun LazyListScope.coachExploreItems(state: CoachState, selected: CoachTrack?, isOpening: Boolean, onOpenPractice: (String) -> Unit) {
    item(key = "explore_intro") {
        Column(Modifier.fillMaxWidth().padding(horizontal = 24.dp, vertical = 10.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(stringResource(R.string.nm_coach_explore_title), style = MaterialTheme.typography.headlineMedium, fontWeight = FontWeight.Bold)
            Text(stringResource(R.string.nm_coach_chat_city_intro), style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
    selected?.let { track -> item(key = "explore_continue") { ContinueCard(track, state, isOpening, onOpenPractice) } }
    item(key = "explore_heading") {
        // 标题和入口按实际文字宽度换行，避免大字号或较长翻译相互挤压。
        FlowRow(Modifier.fillMaxWidth().padding(horizontal = 24.dp), horizontalArrangement = Arrangement.SpaceBetween,
            verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(stringResource(R.string.nm_coach_explore_areas), Modifier.align(Alignment.CenterVertically).padding(end = 12.dp), style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
            TextButton(onClick = { CoachUi.open("courses") }, modifier = Modifier.align(Alignment.CenterVertically)) {
                Icon(Icons.Outlined.Add, null, Modifier.size(18.dp)); Spacer(Modifier.width(4.dp))
                Text(stringResource(R.string.nm_coach_explore_add))
            }
        }
    }
    items(state.tracks, key = { "scene:${it.course.id}" }, contentType = { "coach_scene" }) { track ->
        CoachSceneCard(track) { CoachUi.selectedCourseId.value = track.course.id; CoachUi.open("training") }
    }
    if (state.tracks.isEmpty()) item(key = "explore_empty") {
        OutlinedButton(onClick = { CoachUi.open("courses") }, modifier = Modifier.padding(horizontal = 20.dp).fillMaxWidth().heightIn(min = 52.dp)) {
            Text(stringResource(R.string.nm_coach_explore_add))
        }
    }
}

/** 继续入口展示当前单元，掌握数仅来源于已验证单元集合。 */
@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun ContinueCard(track: CoachTrack, state: CoachState, isOpening: Boolean, onOpenPractice: (String) -> Unit) {
    val hasActive = state.sessions.any { it.course.id == track.course.id && it.course.version == track.course.version &&
        it.unitId == track.currentUnitId && it.status in setOf("active", "paused", "waiting_real") }
    Surface(Modifier.fillMaxWidth().padding(horizontal = 20.dp), shape = RoundedCornerShape(24.dp), color = MuseTones.fill) {
        Column(Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Text(stringResource(R.string.nm_coach_explore_next), style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Text(track.course.title, style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold)
            Text(track.course.units.firstOrNull { it.id == track.currentUnitId }?.title.orEmpty(), style = MaterialTheme.typography.bodyMedium)
            // 进度先保留完整宽度，按钮在空间不足时独占下一行。
            FlowRow(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween, verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(stringResource(R.string.nm_coach_explore_progress, track.course.units.count { it.id in track.demonstrated }, track.course.units.size),
                    Modifier.align(Alignment.CenterVertically).padding(end = 12.dp), style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                FilledTonalButton(onClick = { onOpenPractice(track.course.id) }, modifier = Modifier.align(Alignment.CenterVertically), enabled = !isOpening && !track.paused, shape = RoundedCornerShape(50)) {
                    Text(stringResource(if (hasActive) R.string.nm_coach_continue else R.string.nm_coach_start))
                    Spacer(Modifier.width(6.dp)); Icon(Icons.AutoMirrored.Outlined.ArrowForward, null, Modifier.size(18.dp))
                }
            }
            if (track.paused) Text(stringResource(R.string.nm_coach_paused), style = MaterialTheme.typography.bodySmall)
        }
    }
}

/** 场景图独立成图区，能力、单元和真实进度保持同一文字起点。 */
@Composable
internal fun CoachSceneCard(track: CoachTrack, onClick: () -> Unit) {
    val total = track.course.units.size
    val demonstrated = track.course.units.count { it.id in track.demonstrated }
    Surface(onClick = onClick, modifier = Modifier.fillMaxWidth().padding(horizontal = 20.dp),
        shape = RoundedCornerShape(24.dp), color = MuseTones.surface, border = BorderStroke(1.dp, MuseTones.hairline.copy(alpha = .65f))) {
        Column(Modifier.padding(18.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            CoachSceneArt(track.course.kind, Modifier.fillMaxWidth().height(136.dp))
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text(coachPlaceName(track.course), style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    Text(track.course.title, style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold)
                }
                Icon(Icons.AutoMirrored.Outlined.ArrowForward, null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            Text(track.course.units.firstOrNull { it.id == track.currentUnitId }?.title.orEmpty(), style = MaterialTheme.typography.bodyMedium)
            Text(stringResource(R.string.nm_coach_explore_progress, demonstrated, total), style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            LinearProgressIndicator(progress = { if (total == 0) 0f else demonstrated.toFloat() / total },
                modifier = Modifier.fillMaxWidth().height(3.dp), color = MaterialTheme.colorScheme.onSurface.copy(alpha = .5f), trackColor = MuseTones.fill)
            if (track.paused) Text(stringResource(R.string.nm_coach_paused), style = MaterialTheme.typography.labelSmall)
        }
    }
}

/** 场所名称仍使用课程语义，图形独立表达训练主题。 */
@Composable
internal fun coachPlaceName(course: CoachCourse): String = when (course.kind) {
    CoachKind.JUDGMENT -> stringResource(R.string.nm_coach_place_judgment)
    CoachKind.PERSPECTIVES -> stringResource(R.string.nm_coach_place_perspectives)
    CoachKind.ENGLISH -> stringResource(R.string.nm_coach_place_english)
    CoachKind.EXPRESSION -> stringResource(R.string.nm_coach_place_expression)
    CoachKind.LEADERSHIP -> stringResource(R.string.nm_coach_place_leadership)
    CoachKind.EXECUTION -> stringResource(R.string.nm_coach_place_execution)
    CoachKind.CUSTOM -> course.place.ifBlank { course.title }
}
