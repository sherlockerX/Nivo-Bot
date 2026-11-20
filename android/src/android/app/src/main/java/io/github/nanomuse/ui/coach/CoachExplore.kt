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
