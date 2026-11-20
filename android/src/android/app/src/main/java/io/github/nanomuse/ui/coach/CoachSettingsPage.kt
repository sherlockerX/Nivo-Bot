package io.github.nanomuse.ui.coach

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.selection.toggleable
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.KeyboardArrowRight
import androidx.compose.material.icons.outlined.Check
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.openminis.app.R
import com.openminis.app.data.repository.ProviderRepository
import io.github.nanomuse.coach.CoachLessonPrep
import io.github.nanomuse.coach.CoachPrepSettings
import io.github.nanomuse.coach.CoachState
import io.github.nanomuse.ui.feed.FeedUi
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * 教练设置：备课子智能体（做什么、不做什么、开关、模型、默认时长）、各课程加载的skill、
 * 最近几次备课的结果，以及课程库、训练日历和旧版训练设置的入口。
 * 每组不超过几项，每项下面直接写出当前值。
 */
@Composable
internal fun CoachSettingsPage(state: CoachState, providers: ProviderRepository?) {
    Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
        PrepAgentPanel(providers)
        SkillsPanel(state)
        RecentRunsPanel(state)
        MorePanel()
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun PrepAgentPanel(providers: ProviderRepository?) {
    val context = LocalContext.current
    val revision by CoachPrepSettings.revision.collectAsState()
    val settings = remember(revision) { CoachPrepSettings.read(context) }
    val choices = remember(providers) { providers?.let { CoachLessonPrep.modelChoices(it) }.orEmpty() }
    val defaultEntry = remember(providers) { providers?.let { CoachLessonPrep.candidate(it) } }
    val chosen = choices.firstOrNull { it.id == settings.modelEntryId }
    var isChoosingModel by remember { mutableStateOf(false) }
    Panel {
        SectionTitle(stringResource(R.string.nm_coach_settings_prep))
        Text(stringResource(R.string.nm_coach_settings_prep_body), style = MaterialTheme.typography.bodyMedium)
        Text(stringResource(R.string.nm_coach_settings_prep_limits), style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant)
        HorizontalDivider(color = io.github.nanomuse.ui.home.MuseTones.hairline)
        Row(Modifier.fillMaxWidth().heightIn(min = 56.dp)
            .toggleable(value = settings.isEnabled, role = Role.Switch) { CoachPrepSettings.setEnabled(context, it) },
            verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f).padding(end = 12.dp)) {
                Text(stringResource(R.string.nm_coach_settings_prep_enabled), style = MaterialTheme.typography.bodyLarge)
                Text(stringResource(if (settings.isEnabled) R.string.nm_coach_settings_prep_on else R.string.nm_coach_settings_prep_off),
                    style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            Switch(checked = settings.isEnabled, onCheckedChange = null)
        }
        HorizontalDivider(color = io.github.nanomuse.ui.home.MuseTones.hairline)
        Box {
            val modelValue = chosen?.model?.displayName
                ?: stringResource(R.string.nm_coach_settings_model_default,
                    defaultEntry?.model?.displayName ?: stringResource(R.string.nm_coach_settings_model_none))
            SettingRow(stringResource(R.string.nm_coach_settings_model), modelValue, enabled = settings.isEnabled) {
                isChoosingModel = true
            }
            DropdownMenu(expanded = isChoosingModel, onDismissRequest = { isChoosingModel = false }) {
                DropdownMenuItem(
                    text = { Text(stringResource(R.string.nm_coach_settings_model_default,
                        defaultEntry?.model?.displayName ?: stringResource(R.string.nm_coach_settings_model_none))) },
                    trailingIcon = if (chosen == null) ({ Icon(Icons.Outlined.Check, null) }) else null,
                    onClick = { CoachPrepSettings.setModel(context, ""); isChoosingModel = false },
                    modifier = Modifier.semantics { selected = chosen == null },
                )
                choices.forEach { entry ->
                    DropdownMenuItem(
                        text = { Text(entry.model.displayName) },
                        trailingIcon = if (entry.id == chosen?.id) ({ Icon(Icons.Outlined.Check, null) }) else null,
                        onClick = { CoachPrepSettings.setModel(context, entry.id); isChoosingModel = false },
                        modifier = Modifier.semantics { selected = entry.id == chosen?.id },
                    )
                }
            }
        }
        HorizontalDivider(color = io.github.nanomuse.ui.home.MuseTones.hairline)
        Text(stringResource(R.string.nm_coach_settings_minutes), style = MaterialTheme.typography.bodyLarge)
        FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            CoachPrepSettings.MINUTE_CHOICES.forEach { value ->
                FilterChip(selected = settings.defaultMinutes == value,
                    onClick = { CoachPrepSettings.setDefaultMinutes(context, value) },
                    label = { Text(stringResource(R.string.nm_coach_profile_minutes, value)) },
                    modifier = Modifier.semantics { selected = settings.defaultMinutes == value })
            }
        }
    }
}

/** 每门课程备课时读取的skill及其版本，方便核对教案依据。 */
@Composable
private fun SkillsPanel(state: CoachState) {
    val context = LocalContext.current
    val versions by produceState(emptyMap<String, String>(), state.tracks) {
        value = withContext(Dispatchers.IO) {
            state.tracks.flatMap { CoachLessonPrep.skillIds(it.course) }.distinct().associateWith { id ->
                CoachLessonPrep.skillText(context, id)?.let(CoachLessonPrep::skillVersion).orEmpty()
            }
        }
    }
    Panel {
        SectionTitle(stringResource(R.string.nm_coach_settings_skills))
        Text(stringResource(R.string.nm_coach_settings_skills_body), style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant)
        state.tracks.forEach { track ->
            val ids = CoachLessonPrep.skillIds(track.course).joinToString("、") { id ->
                versions[id]?.takeIf { it.isNotBlank() }?.let { "$id $it" } ?: id
            }
            Column(Modifier.padding(vertical = 2.dp)) {
                Text(track.course.title, style = MaterialTheme.typography.bodyMedium, fontWeight = FontWeight.Medium)
                Text(ids, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
    }
}

/** 最近几次备课：何时、哪项技能、由谁准备、调用几次、用时多久，降级时写明原因。 */
@Composable
private fun RecentRunsPanel(state: CoachState) {
    val runs = remember(state.plans) { state.plans.sortedByDescending { it.createdAt }.take(5) }
    Panel {
        SectionTitle(stringResource(R.string.nm_coach_settings_runs))
        if (runs.isEmpty()) Text(stringResource(R.string.nm_coach_settings_runs_empty), style = MaterialTheme.typography.bodySmall)
        runs.forEach { plan ->
            val title = state.tracks.firstOrNull { it.course.id == plan.courseId }?.course?.title ?: plan.courseId
            val time = Instant.ofEpochMilli(plan.createdAt).atZone(ZoneId.systemDefault())
                .format(DateTimeFormatter.ofLocalizedDateTime(FormatStyle.MEDIUM, FormatStyle.SHORT))
            val detail = if (plan.source == "base") stringResource(degradeText(plan.degradeReason.ifBlank { "prep_off" }))
                else stringResource(R.string.nm_coach_settings_run_prepared, plan.model.ifBlank { "-" }, plan.attempts,
                    String.format(java.util.Locale.ROOT, "%.1f", plan.elapsedMs / 1000.0))
            Column(Modifier.padding(vertical = 2.dp)) {
                Text("$time · $title", style = MaterialTheme.typography.bodyMedium, fontWeight = FontWeight.Medium)
                Text(detail, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
    }
}

@Composable
private fun MorePanel() {
    Panel {
        SectionTitle(stringResource(R.string.nm_coach_settings_more))
        SettingRow(stringResource(R.string.nm_coach_home_library), stringResource(R.string.nm_coach_home_add_hint)) {
            CoachUi.open("courses")
        }
        HorizontalDivider(color = io.github.nanomuse.ui.home.MuseTones.hairline)
        SettingRow(stringResource(R.string.nm_growth_calendar), stringResource(R.string.nm_coach_settings_calendar_hint)) {
            FeedUi.calendarOpen.value = true
        }
        HorizontalDivider(color = io.github.nanomuse.ui.home.MuseTones.hairline)
        SettingRow(stringResource(R.string.nm_coach_settings_legacy), stringResource(R.string.nm_coach_settings_legacy_hint)) {
            FeedUi.settingsOpen.value = true
        }
    }
}

/** 标题加当前值的一行，整行可点。 */
@Composable
private fun SettingRow(title: String, value: String, enabled: Boolean = true, onClick: () -> Unit) {
    Row(Modifier.fillMaxWidth().heightIn(min = 56.dp).clickable(enabled = enabled, role = Role.Button, onClick = onClick),
        verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f).padding(end = 12.dp)) {
            Text(title, style = MaterialTheme.typography.bodyLarge,
                color = if (enabled) MaterialTheme.colorScheme.onSurface else MaterialTheme.colorScheme.onSurfaceVariant)
            Text(value, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        Icon(Icons.AutoMirrored.Outlined.KeyboardArrowRight, null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}
