package io.github.nanomuse.ui.coach

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowForward
import androidx.compose.material.icons.automirrored.outlined.KeyboardArrowRight
import androidx.compose.material.icons.outlined.Add
import androidx.compose.material3.Button
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.openminis.app.R
import io.github.nanomuse.coach.CoachDay
import io.github.nanomuse.coach.CoachOpenChoice
import io.github.nanomuse.coach.CoachSkillProfile
import io.github.nanomuse.coach.CoachState
import io.github.nanomuse.coach.CoachTodayState
import io.github.nanomuse.coach.CoachTrack
import io.github.nanomuse.ui.home.MuseTones
import java.time.ZoneId

/**
 * 教练首页：先给出要继续的那一节，再列出全部技能。每张技能卡只显示当前单元、
 * 进度和今天的状态，完整档案点开后再看，避免首页一次铺开所有内容。
 */
internal fun LazyListScope.coachHomeItems(state: CoachState, isOpening: Boolean, onOpenPractice: (String) -> Unit) {
    item(key = "home_intro") {
        Text(stringResource(R.string.nm_coach_home_intro), style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(horizontal = 24.dp))
    }
    item(key = "home_continue") { ContinueCard(state, isOpening, onOpenPractice) }
    if (state.tracks.isNotEmpty()) item(key = "home_skills_label") {
        Text(stringResource(R.string.nm_coach_home_skills, state.tracks.size), style = MaterialTheme.typography.titleMedium,
            fontWeight = FontWeight.SemiBold, modifier = Modifier.padding(horizontal = 24.dp, vertical = 4.dp))
    }
    items(state.tracks, key = { "home_skill:${it.course.id}" }, contentType = { "coach_skill_card" }) { track ->
        SkillCard(state, track)
    }
    item(key = "home_add") { AddSkillCard(isEmpty = state.tracks.isEmpty()) }
}

/** 有未完成的课节时，首页最上方只给一个继续入口，指向最近练过的那项技能。 */
@Composable
private fun ContinueCard(state: CoachState, isOpening: Boolean, onOpenPractice: (String) -> Unit) {
    val zone = ZoneId.systemDefault()
    val today = CoachDay.key(System.currentTimeMillis(), zone)
    val open = remember(state, today) {
        state.tracks.filter { !it.paused }.mapNotNull { track ->
            val facts = CoachSkillProfile.today(state, track.course.id, today, zone)
            facts.openLesson?.let { track to it }
        }.maxByOrNull { it.first.lastPracticedAt }
    } ?: return
    val (track, lesson) = open
    val unit = track.course.units.firstOrNull { it.id == lesson.unitId }
    Surface(Modifier.fillMaxWidth().padding(horizontal = 16.dp), shape = RoundedCornerShape(22.dp), color = MuseTones.fill) {
        Column(Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(stringResource(R.string.nm_coach_home_continue_label), style = MaterialTheme.typography.labelMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant)
            Text(track.course.title, style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold)
            unit?.let { Text(it.title, style = MaterialTheme.typography.bodyMedium, maxLines = 2, overflow = TextOverflow.Ellipsis) }
            Button(enabled = !isOpening, onClick = {
                CoachUi.requestStart(CoachStartRequest(track.course.id, CoachOpenChoice.CONTINUE))
                onOpenPractice(track.course.id)
            }, modifier = Modifier.heightIn(min = 48.dp)) {
                Text(stringResource(R.string.nm_coach_profile_continue))
                Spacer(Modifier.width(6.dp))
                Icon(Icons.AutoMirrored.Outlined.ArrowForward, null, Modifier.size(18.dp))
            }
        }
    }
}

/** 一项技能的摘要卡：当前单元、达成进度和今天的状态；点开进入技能档案。 */
@Composable
private fun SkillCard(state: CoachState, track: CoachTrack) {
    val context = LocalContext.current
    val total = track.course.units.size
    val demonstrated = track.course.units.count { it.id in track.demonstrated }
    val index = track.course.units.indexOfFirst { it.id == track.currentUnitId }
    val unit = track.course.units.getOrNull(index)
    val status = skillStatus(state, track)
    val progress = stringResource(R.string.nm_coach_home_progress, demonstrated, total)
    Surface(onClick = { CoachUi.openSkill(context, track.course.id) },
        modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp),
        shape = RoundedCornerShape(20.dp), color = MuseTones.surface, border = BorderStroke(1.dp, MuseTones.hairline.copy(alpha = .65f))) {
        Row(Modifier.padding(horizontal = 18.dp, vertical = 16.dp), verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(track.course.title, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold,
                        maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f, fill = false))
                    status?.let { StatusChip(it) }
                }
                if (unit != null) Text(stringResource(R.string.nm_coach_profile_unit, index + 1, total, unit.title),
                    style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1, overflow = TextOverflow.Ellipsis)
                LinearProgressIndicator(progress = { if (total == 0) 0f else demonstrated.toFloat() / total },
                    modifier = Modifier.fillMaxWidth().height(4.dp), color = MaterialTheme.colorScheme.primary, trackColor = MuseTones.fill)
                Text(progress, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            Icon(Icons.AutoMirrored.Outlined.KeyboardArrowRight, null, Modifier.padding(start = 8.dp),
                tint = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

/** 状态用文字表达，不只靠颜色。 */
@Composable
private fun StatusChip(text: String) {
    Surface(shape = RoundedCornerShape(50), color = MuseTones.fill, modifier = Modifier.padding(start = 8.dp)) {
        Text(text, style = MaterialTheme.typography.labelSmall, maxLines = 1,
            modifier = Modifier.padding(horizontal = 8.dp, vertical = 3.dp))
    }
}

@Composable
private fun skillStatus(state: CoachState, track: CoachTrack): String? {
    if (track.paused) return stringResource(R.string.nm_coach_home_status_paused)
    if (track.course.needsCriteriaReview || track.course.units.any { it.needsCriteriaReview }) {
        return stringResource(R.string.nm_coach_home_status_review)
    }
    val zone = ZoneId.systemDefault()
    val today = CoachDay.key(System.currentTimeMillis(), zone)
    return when (CoachSkillProfile.today(state, track.course.id, today, zone).state) {
        CoachTodayState.IN_PROGRESS -> stringResource(R.string.nm_coach_home_status_in_progress)
        CoachTodayState.EARLIER_UNFINISHED -> stringResource(R.string.nm_coach_home_status_unfinished)
        CoachTodayState.DONE -> stringResource(R.string.nm_coach_home_status_done)
        CoachTodayState.NOT_STARTED -> null
    }
}

/** 列表末尾的新建入口：打开课程库，可以让AI一起设计一门新技能。 */
@Composable
private fun AddSkillCard(isEmpty: Boolean) {
    Surface(onClick = { CoachUi.open("courses") }, modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp),
        shape = RoundedCornerShape(20.dp), color = androidx.compose.ui.graphics.Color.Transparent,
        border = BorderStroke(1.dp, MuseTones.hairline)) {
        Row(Modifier.padding(horizontal = 18.dp, vertical = 16.dp).semantics(mergeDescendants = true) {},
            verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Outlined.Add, null, Modifier.size(22.dp))
            Column(Modifier.padding(start = 12.dp).weight(1f)) {
                Text(stringResource(if (isEmpty) R.string.nm_coach_profile_empty_title else R.string.nm_coach_home_add),
                    style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold)
                Text(stringResource(R.string.nm_coach_home_add_hint), style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
    }
}
